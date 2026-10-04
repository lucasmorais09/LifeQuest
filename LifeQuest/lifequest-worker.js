/**
 * Servidor do LifeQuest (Cloudflare Worker) - etapa 4
 *
 * Rotas:
 *   POST /validar  Valida a selfie com IA e, se aprovada, registra a conclusão no banco
 *                  (pontos, moedas e troféus são calculados pelo próprio banco).
 *   POST /         Pergunta livre à IA (usada pelas sugestões do relatório detalhado).
 * As duas exigem um usuário logado: o app envia o token do login do Supabase.
 *
 * Configuração do Worker (Configurações > Variáveis e segredos / Bindings):
 *   AI                         binding do Workers AI (o mesmo de antes)
 *   SUPABASE_URL               variável: https://bopulowmqkxagwicunoe.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY  SEGREDO: chave secreta do Supabase (sb_secret_... ou service_role)
 *   ALLOWED_ORIGIN             opcional: endereço do app no Netlify (ex.: https://lifequest.netlify.app)
 *   APROVAR_SE_IA_FALHAR       opcional: "sim" aprova automaticamente quando a IA estiver fora do ar
 *                              (útil em apresentação; deixe vazio no uso normal)
 */
const MODEL = '@cf/meta/llama-4-scout-17b-16e-instruct';
const MAX_PROMPT = 20000;
const MAX_IMAGE_B64 = 7000000; // ~5 MB
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATA = /^\d{4}-\d{2}-\d{2}$/;

export default {
  async fetch(request, env) {
    // CORS: o navegador só entrega a resposta ao app se este cabeçalho bater com o endereço do app.
    // ALLOWED_ORIGIN aceita um ou mais endereços separados por vírgula; barras no final são ignoradas.
    const origem = (request.headers.get('Origin') || '').replace(/\/+$/, '');
    const permitidas = String(env.ALLOWED_ORIGIN || '').split(',').map(s => s.trim().replace(/\/+$/, '')).filter(Boolean);
    const origemOk = !permitidas.length || permitidas.includes(origem);
    const cors = {
      'Access-Control-Allow-Origin': permitidas.length ? (origem || permitidas[0]) : '*',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Vary': 'Origin',
    };
    const json = (obj, status = 200) =>
      new Response(JSON.stringify(obj), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

    // Qualquer erro, em qualquer ponto, volta como JSON com CORS: o app sempre consegue mostrar a causa
    try {
      if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
      if (request.method !== 'POST') return json({ ok: true, info: 'Servidor do LifeQuest no ar. Use POST.' }, 200);
      if (!origemOk) {
        console.error('Origem recusada:', origem, '| ALLOWED_ORIGIN =', env.ALLOWED_ORIGIN);
        return json({ error: `Este app (${origem || 'origem desconhecida'}) não está autorizado no servidor. Confira a variável ALLOWED_ORIGIN do Worker.` }, 403);
      }
      if (!env.AI) return json({ error: 'Binding "AI" não configurado no Worker.' }, 500);
      if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY)
        return json({ error: 'SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY não configurados no Worker.' }, 500);

      const db = supabase(env);
      const user = await db.usuarioDoToken(request.headers.get('Authorization'));
      if (!user) return json({ error: 'Faça login novamente.' }, 401);

      let body;
      try { body = await request.json(); } catch { return json({ error: 'JSON inválido.' }, 400); }

      const path = new URL(request.url).pathname.replace(/\/+$/, '');
      if (path === '/validar') return json(await validar(env, db, user, body));
      if (path === '') return json(await perguntar(env, body));
      return json({ error: 'Rota inexistente.' }, 404);
    } catch (e) {
      console.error('Erro:', e.status || 500, e.message, e.stack);
      return json({ error: e.publico || 'Erro interno no servidor: ' + String(e.message || e) }, e.status || 500);
    }
  },
};

// ---------------------------------------------------------------------
// POST /validar  {atividade_id, data, foto (base64 JPEG)}
// ---------------------------------------------------------------------
async function validar(env, db, user, body) {
  const { atividade_id, data, foto } = body || {};
  if (!UUID.test(atividade_id || '') || !DATA.test(data || '')) throw erro(400, 'Atividade ou data inválida.');
  if (typeof foto !== 'string' || !foto || foto.length > MAX_IMAGE_B64) throw erro(413, 'Foto ausente ou grande demais.');

  // 1. A atividade existe e é do usuário?
  const [ativ] = await db.get(`atividades?id=eq.${atividade_id}&select=id,usuario_id,titulo,ambito_id`);
  if (!ativ || ativ.usuario_id !== user.id) throw erro(404, 'Atividade não encontrada.');
  const [amb] = await db.get(`ambitos?id=eq.${ativ.ambito_id}&select=nome`);

  // 2. A IA analisa a selfie
  let veredito;
  try {
    veredito = await analisarFoto(env, ativ.titulo, amb ? amb.nome : '', foto);
  } catch (e) {
    if (String(env.APROVAR_SE_IA_FALHAR || '').toLowerCase() === 'sim')
      veredito = { aprovado: true, motivo: 'A IA estava indisponível; aprovação automática do modo de apresentação.' };
    else throw erro(503, 'A IA está indisponível agora (a cota gratuita do dia pode ter acabado). Tente de novo mais tarde.');
  }

  // 3. Foto aprovada vai para o armazenamento; recusada não é guardada
  let fotoUrl = 'nao_armazenada';
  if (veredito.aprovado) fotoUrl = await db.enviarFoto(`${user.id}/${crypto.randomUUID()}.jpg`, foto);

  // 4. O banco registra a tentativa e, se aprovada, credita pontos e concede troféus
  const r = await db.rpc('registrar_conclusao', {
    p_atividade: atividade_id, p_data: data, p_foto_url: fotoUrl,
    p_aprovada: veredito.aprovado, p_motivo: veredito.motivo, p_modelo: MODEL,
  });
  const linha = Array.isArray(r) ? r[0] : r;
  const resposta = { aprovado: veredito.aprovado, motivo: veredito.motivo, pontos: linha?.pontos_ganhos || 0, trofeus: [] };
  if (!veredito.aprovado) return resposta;

  const ids = linha?.trofeus_novos || [];
  if (ids.length) resposta.trofeus = await db.get(`trofeus?id=in.(${ids.join(',')})&select=id,tipo,nome,descricao,marco,conquistado_em`);
  const [ex] = await db.get(`execucoes?atividade_id=eq.${atividade_id}&data_ocorrencia=eq.${data}&select=id,concluida_em,duracao_min`);
  const [saldo] = await db.get(`usuarios?id=eq.${user.id}&select=pontos,moedas`);
  return { ...resposta, foto_url: fotoUrl, execucao: ex, saldo };
}

async function analisarFoto(env, titulo, ambito, fotoB64) {
  const prompt = `Você é o validador de comprovações do aplicativo LifeQuest, que transforma hábitos em jogo.
O usuário diz ter concluído a atividade "${titulo}" (âmbito: ${ambito}).
Analise a foto e aprove SOMENTE se as duas condições forem verdadeiras:
1) É uma selfie ou foto em que o rosto de uma pessoa aparece de forma visível.
2) O fundo ou a cena mostra evidência plausível relacionada à atividade.
Seja razoável, mas rejeite fotos sem rosto, fotos de tela ou imagens sem relação com a atividade.
Responda APENAS com JSON: {"aprovado": true ou false, "motivo": "uma frase curta em português, falando com o usuário"}`;
  const result = await env.AI.run(MODEL, {
    messages: [
      { role: 'system', content: 'Você responde sempre em português do Brasil e apenas com JSON válido.' },
      { role: 'user', content: [
        { type: 'text', text: prompt },
        { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${fotoB64}` } },
      ] },
    ],
    max_tokens: 300,
    temperature: 0.1,
  });
  const r = result && result.response;
  console.log('Resposta da IA:', typeof r === 'string' ? r.slice(0, 500) : JSON.stringify(r));
  let obj;
  try {
    obj = typeof r === 'object' && r !== null ? r : extrairJson(String(r || ''));
  } catch {
    // A IA respondeu fora do formato (ex.: recusou analisar a imagem). Isso não é falha
    // do servidor: a foto simplesmente não pôde ser confirmada, então é recusada.
    return { aprovado: false, motivo: 'Não consegui confirmar seu rosto e a atividade nesta foto. Tente outra, com boa luz e a tarefa aparecendo ao fundo.' };
  }
  const aprovado = obj.aprovado === true || obj.aprovado === 'true';
  const motivo = String(obj.motivo || '').slice(0, 300) ||
    (aprovado ? 'Foto aprovada.' : 'A foto não mostrou seu rosto e a atividade ao fundo.');
  return { aprovado, motivo };
}

// ---------------------------------------------------------------------
// POST /  {prompt, image?}  pergunta livre (sugestões do relatório)
// ---------------------------------------------------------------------
async function perguntar(env, body) {
  const { prompt, image } = body || {};
  if (typeof prompt !== 'string' || !prompt || prompt.length > MAX_PROMPT) throw erro(400, 'Prompt ausente ou grande demais.');
  let content = prompt;
  if (image) {
    if (typeof image.data !== 'string' || image.data.length > MAX_IMAGE_B64) throw erro(413, 'Imagem grande demais.');
    content = [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: `data:${image.media_type || 'image/jpeg'};base64,${image.data}` } }];
  }
  try {
    const result = await env.AI.run(MODEL, {
      messages: [
        { role: 'system', content: 'Você responde sempre em português do Brasil e, quando pedido, apenas com JSON válido.' },
        { role: 'user', content },
      ],
      max_tokens: 1500, temperature: 0.2,
    });
    const r = result && result.response;
    return { text: typeof r === 'string' ? r : JSON.stringify(r ?? '') };
  } catch (e) {
    throw erro(429, 'A IA está indisponível agora. Tente de novo mais tarde.');
  }
}

// ---------------------------------------------------------------------
// Acesso ao Supabase com a chave secreta (só existe aqui no servidor)
// ---------------------------------------------------------------------
function supabase(env) {
  const base = env.SUPABASE_URL.replace(/\/+$/, '');
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  // chaves novas (sb_secret_...) vão só no cabeçalho apikey; a antiga service_role (JWT) vai nos dois
  const svc = key.startsWith('eyJ') ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key };

  async function req(url, init = {}) {
    const res = await fetch(url, { ...init, headers: { ...svc, ...(init.headers || {}) } });
    const txt = await res.text();
    const dados = txt ? JSON.parse(txt) : null;
    if (!res.ok) {
      const msg = (dados && (dados.message || dados.error || dados.msg)) || `HTTP ${res.status}`;
      // erros de regra de negócio do banco (RAISE EXCEPTION) chegam ao usuário sem o código RN
      const regra = /RN\d+|já foi concluída|hoje ou de datas passadas|não acontece/.test(msg);
      throw erro(regra ? 409 : 502, regra ? msg.replace(/\s*\(RN\d+\)/, '') : 'Falha ao falar com o banco: ' + msg);
    }
    return dados;
  }

  return {
    async usuarioDoToken(auth) {
      const token = (auth || '').replace(/^Bearer\s+/i, '');
      if (!token) return null;
      let res;
      try { res = await fetch(`${base}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${token}` } }); }
      catch (e) { throw erro(502, 'O servidor não conseguiu falar com o Supabase. Confira a variável SUPABASE_URL do Worker.'); }
      if (!res.ok) return null;
      const u = await res.json();
      return u && u.id ? u : null;
    },
    get: path => req(`${base}/rest/v1/${path}`),
    rpc: (fn, args) => req(`${base}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(args),
    }),
    async enviarFoto(caminho, b64) {
      const bin = atob(b64); const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      await req(`${base}/storage/v1/object/comprovacoes/${caminho}`, {
        method: 'POST', headers: { 'Content-Type': 'image/jpeg', 'x-upsert': 'false' }, body: bytes,
      });
      return `${base}/storage/v1/object/public/comprovacoes/${caminho}`;
    },
  };
}

function extrairJson(t) {
  const s = t.replace(/```json|```/g, '');
  const a = s.indexOf('{'), z = s.lastIndexOf('}');
  if (a < 0 || z < a) throw new Error('Resposta da IA sem JSON');
  return JSON.parse(s.slice(a, z + 1));
}
function erro(status, publico) { const e = new Error(publico); e.status = status; e.publico = publico; return e; }