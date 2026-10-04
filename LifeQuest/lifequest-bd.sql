-- =====================================================================
--  LifeQuest - modelo de dados (PostgreSQL 15 ou superior)
--  Cria tipos, tabelas, restrições, índices, funções de regra de negócio
--  e os dados iniciais (âmbitos padrão e tipos de relatório).
--  As referências RNxx e UCxx seguem o documento de casos de uso.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext;  -- texto que ignora maiúsculas (e-mail)

-- ---------------------------------------------------------------------
-- Tipos enumerados: listas fechadas de valores aceitos
-- ---------------------------------------------------------------------
CREATE TYPE frequencia_t      AS ENUM ('diaria','semanal','mensal','bimestral','trimestral','quadrimestral','semestral','anual'); -- RN16
CREATE TYPE execucao_status_t AS ENUM ('pendente','em_andamento','concluida');
CREATE TYPE trofeu_tipo_t     AS ENUM ('ofensiva','novo_habito','frequencia');
CREATE TYPE publicacao_tipo_t AS ENUM ('atividade','trofeu','relatorio');
CREATE TYPE reacao_tipo_t     AS ENUM ('joia','coracao');                                    -- RN14
CREATE TYPE sugestao_status_t AS ENUM ('pendente','aceita','recusada');
CREATE TYPE movimento_t       AS ENUM ('conclusao','compra_relatorio','ajuste');

-- ---------------------------------------------------------------------
-- 1. usuarios (UC01, UC24, UC25)
-- ---------------------------------------------------------------------
CREATE TABLE usuarios (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email            citext      NOT NULL UNIQUE CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),   -- RN03
  senha_hash       text        NOT NULL,   -- nunca a senha pura; no Supabase fica em auth.users
  nome_usuario     varchar(20) NOT NULL UNIQUE CHECK (nome_usuario ~ '^[a-z0-9._]{3,20}$'), -- RN01
  nome_completo    varchar(120) NOT NULL,
  data_nascimento  date        NOT NULL,
  cor_perfil       char(7)     NOT NULL DEFAULT '#3D7BD9' CHECK (cor_perfil ~ '^#[0-9A-Fa-f]{6}$'),
  mostrar_nome     boolean     NOT NULL DEFAULT false,                                      -- RN25
  fuso_horario     text        NOT NULL DEFAULT 'America/Sao_Paulo', -- define o "dia" do usuário
  pontos           integer     NOT NULL DEFAULT 0 CHECK (pontos >= 0),  -- total acumulado
  moedas           integer     NOT NULL DEFAULT 0 CHECK (moedas >= 0),  -- saldo para relatórios
  criado_em        timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. ambitos: os 7 padrão (criado_por NULL) e os personalizados (UC05, UC06)
-- ---------------------------------------------------------------------
CREATE TABLE ambitos (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  nome        varchar(40) NOT NULL,
  descricao   varchar(120) NOT NULL,
  cor         char(7)     NOT NULL CHECK (cor ~ '^#[0-9A-Fa-f]{6}$'),
  icone       varchar(30) NOT NULL DEFAULT 'star',
  criado_por  uuid        REFERENCES usuarios(id) ON DELETE CASCADE,  -- NULL = âmbito padrão
  criado_em   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_ambitos_padrao ON ambitos (nome) WHERE criado_por IS NULL;

-- ---------------------------------------------------------------------
-- 3. usuario_ambitos: quais âmbitos cada usuário escolheu e quais são prioridade (UC05, UC07)
--    Relação N:N entre usuarios e ambitos.
-- ---------------------------------------------------------------------
CREATE TABLE usuario_ambitos (
  usuario_id     uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  ambito_id      uuid        NOT NULL REFERENCES ambitos(id),
  prioritario    boolean     NOT NULL DEFAULT false,
  adicionado_em  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (usuario_id, ambito_id)
);

-- ---------------------------------------------------------------------
-- 4. atividades (UC09, UC10, UC11)
--    Guarda a REGRA da atividade, não cada dia: as ocorrências são calculadas
--    pela função ocorre_em(). A chave estrangeira composta garante que a
--    atividade só use âmbitos escolhidos pelo usuário e impede remover um
--    âmbito que ainda tem atividades (RN20).
-- ---------------------------------------------------------------------
CREATE TABLE atividades (
  id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id   uuid         NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  ambito_id    uuid         NOT NULL,
  titulo       varchar(60)  NOT NULL CHECK (length(btrim(titulo)) > 0),
  data_inicio  date         NOT NULL,
  hora_inicio  time(0)      NOT NULL,
  hora_fim     time(0),                 -- NULL = sem horário de término
  frequencia   frequencia_t,            -- NULL = não se repete
  criado_em    timestamptz  NOT NULL DEFAULT now(),
  CHECK (hora_fim IS NULL OR hora_fim <> hora_inicio),
  CHECK (extract(minute FROM hora_inicio)::int % 5 = 0),
  FOREIGN KEY (usuario_id, ambito_id) REFERENCES usuario_ambitos (usuario_id, ambito_id)
);
CREATE INDEX ix_atividades_usuario ON atividades (usuario_id);

-- 5. atividade_lembretes: 0 a 3 lembretes por atividade (RN17)
CREATE TABLE atividade_lembretes (
  atividade_id      uuid     NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  antecedencia_min  smallint NOT NULL CHECK (antecedencia_min IN (1440, 60, 10)), -- 1 dia, 1 h, 10 min
  PRIMARY KEY (atividade_id, antecedencia_min)
);

-- ---------------------------------------------------------------------
-- 6. execucoes: o que aconteceu com UMA ocorrência (um dia) de uma atividade
--    (UC13, UC14, UC15). Guarda cópia do título e do âmbito para o histórico
--    sobreviver à exclusão da atividade (UC11).
-- ---------------------------------------------------------------------
CREATE TABLE execucoes (
  id               uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id       uuid              NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  atividade_id     uuid              REFERENCES atividades(id) ON DELETE SET NULL,
  ambito_id        uuid              NOT NULL REFERENCES ambitos(id),
  titulo           varchar(60)       NOT NULL,
  data_ocorrencia  date              NOT NULL,
  status           execucao_status_t NOT NULL DEFAULT 'pendente',
  iniciada_em      timestamptz,      -- toque em "Iniciar" (UC13)
  adiada_ate       timestamptz,      -- último "Adiar 10 min" (UC14, RN18)
  concluida_em     timestamptz,
  duracao_min      integer CHECK (duracao_min >= 0),
  pontos           smallint CHECK (pontos IN (10, 20)),                      -- RN06
  UNIQUE (atividade_id, data_ocorrencia),                                    -- RN08: uma vez por data
  CHECK ((status = 'concluida') = (concluida_em IS NOT NULL AND pontos IS NOT NULL))
);
CREATE INDEX ix_execucoes_concluidas ON execucoes (usuario_id, concluida_em) WHERE status = 'concluida';

-- 7. validacoes_foto: cada selfie enviada e o veredito da IA (UC15, UC16, RN07)
CREATE TABLE validacoes_foto (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  execucao_id  uuid        NOT NULL REFERENCES execucoes(id) ON DELETE CASCADE,
  foto_url     text        NOT NULL,          -- o arquivo fica no storage; aqui só o endereço
  aprovada     boolean     NOT NULL,
  motivo       text,
  modelo_ia    varchar(80),
  enviada_em   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 8. trofeus (UC18, RN09, RN10, RN11). "marco" = dias seguidos (ofensiva)
--    ou quantidade de conclusões (novo hábito, frequência).
-- ---------------------------------------------------------------------
CREATE TABLE trofeus (
  id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id        uuid          NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  tipo              trofeu_tipo_t NOT NULL,
  marco             integer       NOT NULL CHECK (marco > 0),
  ambito_id         uuid          REFERENCES ambitos(id),
  titulo_atividade  varchar(60),
  nome              varchar(90)   NOT NULL,
  descricao         text          NOT NULL,
  execucao_id       uuid          REFERENCES execucoes(id) ON DELETE SET NULL,
  conquistado_em    timestamptz   NOT NULL DEFAULT now(),
  CHECK (tipo <> 'ofensiva' OR marco IN (7, 30, 60, 90, 365, 548, 730, 913)),
  CHECK ((tipo = 'novo_habito') = (ambito_id IS NOT NULL)),
  CHECK ((tipo = 'frequencia')  = (titulo_atividade IS NOT NULL))
);
-- cada marco só pode ser ganho uma vez
CREATE UNIQUE INDEX ux_trofeu_ofensiva   ON trofeus (usuario_id, marco)                         WHERE tipo = 'ofensiva';
CREATE UNIQUE INDEX ux_trofeu_habito     ON trofeus (usuario_id, ambito_id, marco)              WHERE tipo = 'novo_habito';
CREATE UNIQUE INDEX ux_trofeu_frequencia ON trofeus (usuario_id, lower(titulo_atividade), marco) WHERE tipo = 'frequencia';

-- ---------------------------------------------------------------------
-- 9. seguidores: relação N:N de usuarios com ele mesmo (UC20)
-- ---------------------------------------------------------------------
CREATE TABLE seguidores (
  seguidor_id  uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  seguido_id   uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  criado_em    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (seguidor_id, seguido_id),
  CHECK (seguidor_id <> seguido_id)
);
CREATE INDEX ix_seguidores_seguido ON seguidores (seguido_id);

-- ---------------------------------------------------------------------
-- 10. tipos_relatorio: catálogo de insights e preços (RN15, RN24)
-- 11. relatorios: cada compra, com período retratado e expiração (UC26)
-- ---------------------------------------------------------------------
CREATE TABLE tipos_relatorio (
  codigo        varchar(20) PRIMARY KEY,
  nome          varchar(60) NOT NULL,
  descricao     text        NOT NULL,
  preco_moedas  integer     NOT NULL CHECK (preco_moedas > 0),
  validade      interval    NOT NULL DEFAULT interval '3 days',
  usa_ia        boolean     NOT NULL DEFAULT false,
  ordem         smallint    NOT NULL
);

CREATE TABLE relatorios (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id      uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  tipo            varchar(20) NOT NULL REFERENCES tipos_relatorio(codigo),
  preco_pago      integer     NOT NULL CHECK (preco_pago > 0),  -- histórico, se o preço mudar
  periodo_inicio  date        NOT NULL,
  periodo_fim     date        NOT NULL,
  dados           jsonb       NOT NULL DEFAULT '{}'::jsonb,     -- "foto" dos números no momento da compra
  comprado_em     timestamptz NOT NULL DEFAULT now(),
  expira_em       timestamptz NOT NULL,
  CHECK (periodo_fim >= periodo_inicio),
  CHECK (expira_em > comprado_em)
);
CREATE INDEX ix_relatorios_usuario ON relatorios (usuario_id, tipo, expira_em DESC);

-- 12. sugestoes_ia: as 5 atividades propostas no relatório detalhado (UC27, RN23)
--     Os lembretes ficam num vetor porque a sugestão é só uma proposta;
--     ao ser aceita, vira uma linha em atividades + atividade_lembretes.
CREATE TABLE sugestoes_ia (
  id            uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  relatorio_id  uuid              NOT NULL REFERENCES relatorios(id) ON DELETE CASCADE,
  ambito_id     uuid              NOT NULL REFERENCES ambitos(id),
  titulo        varchar(60)       NOT NULL,
  data_inicio   date              NOT NULL,
  hora_inicio   time(0)           NOT NULL,
  hora_fim      time(0),
  frequencia    frequencia_t,
  lembretes     smallint[]        NOT NULL DEFAULT '{}' CHECK (lembretes <@ ARRAY[1440, 60, 10]::smallint[]),
  motivo        text,
  status        sugestao_status_t NOT NULL DEFAULT 'pendente',
  atividade_id  uuid              REFERENCES atividades(id) ON DELETE SET NULL  -- a atividade criada ao aceitar
);

-- ---------------------------------------------------------------------
-- 13. publicacoes (UC22, UC23): cada post aponta para exatamente UMA origem
-- 14. reacoes (UC21): joia e coração, um de cada por pessoa (RN14)
-- ---------------------------------------------------------------------
CREATE TABLE publicacoes (
  id            uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id    uuid              NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  tipo          publicacao_tipo_t NOT NULL,
  execucao_id   uuid              REFERENCES execucoes(id)  ON DELETE CASCADE,
  trofeu_id     uuid              REFERENCES trofeus(id)    ON DELETE CASCADE,
  relatorio_id  uuid              REFERENCES relatorios(id) ON DELETE CASCADE,
  foto_url      text,
  resumo        jsonb,            -- números exibidos no card do relatório
  criado_em     timestamptz       NOT NULL DEFAULT now(),
  CHECK (
    (tipo = 'atividade' AND execucao_id  IS NOT NULL AND trofeu_id IS NULL   AND relatorio_id IS NULL) OR
    (tipo = 'trofeu'    AND trofeu_id    IS NOT NULL AND execucao_id IS NULL AND relatorio_id IS NULL) OR
    (tipo = 'relatorio' AND relatorio_id IS NOT NULL AND execucao_id IS NULL AND trofeu_id IS NULL)
  )
);
CREATE INDEX ix_publicacoes_feed ON publicacoes (criado_em DESC);

CREATE TABLE reacoes (
  publicacao_id  uuid          NOT NULL REFERENCES publicacoes(id) ON DELETE CASCADE,
  usuario_id     uuid          NOT NULL REFERENCES usuarios(id)    ON DELETE CASCADE,
  tipo           reacao_tipo_t NOT NULL,
  criado_em      timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (publicacao_id, usuario_id, tipo)
);

-- ---------------------------------------------------------------------
-- 15. movimentacoes_moedas: extrato de moedas. O saldo em usuarios.moedas
--     é sempre a soma deste extrato, o que permite auditar pontos.
-- ---------------------------------------------------------------------
CREATE TABLE movimentacoes_moedas (
  id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  usuario_id    uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  valor         integer     NOT NULL CHECK (valor <> 0),
  motivo        movimento_t NOT NULL,
  execucao_id   uuid        REFERENCES execucoes(id)  ON DELETE SET NULL,
  relatorio_id  uuid        REFERENCES relatorios(id) ON DELETE SET NULL,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  CHECK (motivo <> 'conclusao'        OR valor > 0),
  CHECK (motivo <> 'compra_relatorio' OR valor < 0)
);
CREATE INDEX ix_movimentacoes_usuario ON movimentacoes_moedas (usuario_id, criado_em);

-- 16. mensagens_suporte (UC24)
CREATE TABLE mensagens_suporte (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id  uuid        REFERENCES usuarios(id) ON DELETE SET NULL,
  email       citext      NOT NULL,
  assunto     varchar(60) NOT NULL,
  mensagem    text        NOT NULL CHECK (length(btrim(mensagem)) > 0),
  respondida  boolean     NOT NULL DEFAULT false,
  criado_em   timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
--  REGRAS DE NEGÓCIO NO BANCO
-- =====================================================================

-- RN04 e RN05: pelo menos 1 âmbito; limite de prioridades (3+ âmbitos: 2; 2: 1; 1: 0).
-- Gatilho "deferido": a conferência acontece no fim da transação, então o app pode
-- trocar várias marcações de uma vez sem erro no meio do caminho.
CREATE FUNCTION fn_checar_ambitos() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_usuario uuid := COALESCE(NEW.usuario_id, OLD.usuario_id);
  v_total int; v_prio int; v_max int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM usuarios WHERE id = v_usuario) THEN
    RETURN NULL;  -- conta sendo excluída
  END IF;
  SELECT count(*), count(*) FILTER (WHERE prioritario)
    INTO v_total, v_prio FROM usuario_ambitos WHERE usuario_id = v_usuario;
  IF v_total = 0 THEN
    RAISE EXCEPTION 'O usuário precisa ter pelo menos um âmbito (RN04).';
  END IF;
  v_max := CASE WHEN v_total >= 3 THEN 2 WHEN v_total = 2 THEN 1 ELSE 0 END;
  IF v_prio > v_max THEN
    RAISE EXCEPTION 'Com % âmbito(s), no máximo % pode(m) ser prioridade (RN05).', v_total, v_max;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER tg_checar_ambitos
  AFTER INSERT OR UPDATE OR DELETE ON usuario_ambitos
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION fn_checar_ambitos();

-- Recorrência (RN16): a atividade acontece na data d?
CREATE FUNCTION ocorre_em(a atividades, d date) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN d < a.data_inicio      THEN false
    WHEN a.frequencia IS NULL   THEN d = a.data_inicio
    WHEN a.frequencia = 'diaria'  THEN true
    WHEN a.frequencia = 'semanal' THEN (d - a.data_inicio) % 7 = 0
    ELSE extract(day FROM d) = extract(day FROM a.data_inicio)
     AND ((extract(year FROM d) - extract(year FROM a.data_inicio)) * 12
          + extract(month FROM d) - extract(month FROM a.data_inicio))::int
         % CASE a.frequencia WHEN 'mensal' THEN 1 WHEN 'bimestral' THEN 2 WHEN 'trimestral' THEN 3
                             WHEN 'quadrimestral' THEN 4 WHEN 'semestral' THEN 6 ELSE 12 END = 0
  END
$$;

-- Agenda do calendário (UC08): todas as ocorrências de um usuário num intervalo de datas.
CREATE FUNCTION agenda(p_usuario uuid, p_de date, p_ate date)
RETURNS TABLE (data date, atividade_id uuid, titulo varchar, ambito_id uuid,
               hora_inicio time, hora_fim time, status execucao_status_t)
LANGUAGE sql STABLE AS $$
  SELECT dia::date, a.id, a.titulo, a.ambito_id, a.hora_inicio, a.hora_fim,
         COALESCE(e.status, 'pendente')
    FROM generate_series(p_de, p_ate, interval '1 day') AS dia
    JOIN atividades a ON a.usuario_id = p_usuario AND ocorre_em(a, dia::date)
    LEFT JOIN execucoes e ON e.atividade_id = a.id AND e.data_ocorrencia = dia::date
   ORDER BY 1, 5
$$;

-- RN09: dias seguidos com pelo menos uma tarefa validada, terminando em p_ate.
CREATE FUNCTION dias_seguidos(p_usuario uuid, p_ate date) RETURNS int LANGUAGE plpgsql STABLE AS $$
DECLARE v_tz text; v_dia date := p_ate; v_n int := 0;
BEGIN
  SELECT fuso_horario INTO v_tz FROM usuarios WHERE id = p_usuario;
  LOOP
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM execucoes
       WHERE usuario_id = p_usuario AND status = 'concluida'
         AND (concluida_em AT TIME ZONE v_tz)::date = v_dia);
    v_n := v_n + 1;
    v_dia := v_dia - 1;
  END LOOP;
  RETURN v_n;
END $$;

-- UC15 a UC18: registra o resultado da validação da selfie. Chamada SOMENTE pelo
-- servidor, depois que a IA responde. Se aprovada: conclui a ocorrência, credita
-- pontos e moedas (RN06) e concede os troféus devidos (RN09, RN10, RN11).
CREATE FUNCTION registrar_conclusao(
  p_atividade uuid, p_data date, p_foto_url text,
  p_aprovada boolean, p_motivo text, p_modelo text DEFAULT NULL)
RETURNS TABLE (pontos_ganhos int, trofeus_novos uuid[])
LANGUAGE plpgsql AS $$
DECLARE
  a atividades; v_tz text; v_hoje date; v_exec execucoes;
  v_pts int; v_novos uuid[] := '{}'; v_id uuid; v_n int;
BEGIN
  SELECT * INTO a FROM atividades WHERE id = p_atividade;
  IF NOT FOUND THEN RAISE EXCEPTION 'Atividade inexistente.'; END IF;
  SELECT fuso_horario INTO v_tz FROM usuarios WHERE id = a.usuario_id;
  v_hoje := (now() AT TIME ZONE v_tz)::date;

  IF p_data > v_hoje THEN RAISE EXCEPTION 'Só é possível concluir ocorrências de hoje ou de datas passadas (RN08).'; END IF;
  IF NOT ocorre_em(a, p_data) THEN RAISE EXCEPTION 'A atividade não acontece em %.', p_data; END IF;

  -- cria (ou trava) a linha da ocorrência
  INSERT INTO execucoes (usuario_id, atividade_id, ambito_id, titulo, data_ocorrencia)
  VALUES (a.usuario_id, a.id, a.ambito_id, a.titulo, p_data)
  ON CONFLICT (atividade_id, data_ocorrencia) DO NOTHING;
  SELECT * INTO v_exec FROM execucoes
   WHERE atividade_id = a.id AND data_ocorrencia = p_data FOR UPDATE;
  IF v_exec.status = 'concluida' THEN RAISE EXCEPTION 'Esta ocorrência já foi concluída (RN08).'; END IF;

  INSERT INTO validacoes_foto (execucao_id, foto_url, aprovada, motivo, modelo_ia)
  VALUES (v_exec.id, p_foto_url, p_aprovada, p_motivo, p_modelo);
  IF NOT p_aprovada THEN
    RETURN QUERY SELECT 0, v_novos; RETURN;                       -- RN07: sem foto aprovada, nada muda
  END IF;

  SELECT CASE WHEN ua.prioritario THEN 20 ELSE 10 END INTO v_pts
    FROM usuario_ambitos ua WHERE ua.usuario_id = a.usuario_id AND ua.ambito_id = a.ambito_id;

  UPDATE execucoes SET status = 'concluida', concluida_em = now(), pontos = v_pts,
         duracao_min = CASE
           WHEN iniciada_em IS NOT NULL THEN GREATEST(0, (extract(epoch FROM now() - iniciada_em) / 60)::int)
           WHEN a.hora_fim IS NOT NULL THEN ((extract(epoch FROM a.hora_fim - a.hora_inicio) / 60)::int + 1440) % 1440
           ELSE 30 END
   WHERE id = v_exec.id;

  INSERT INTO movimentacoes_moedas (usuario_id, valor, motivo, execucao_id)
  VALUES (a.usuario_id, v_pts, 'conclusao', v_exec.id);
  UPDATE usuarios SET pontos = pontos + v_pts, moedas = moedas + v_pts WHERE id = a.usuario_id;

  -- RN09 ofensiva: avaliada na primeira conclusão do dia
  IF (SELECT count(*) FROM execucoes
       WHERE usuario_id = a.usuario_id AND status = 'concluida'
         AND (concluida_em AT TIME ZONE v_tz)::date = v_hoje) = 1 THEN
    v_n := dias_seguidos(a.usuario_id, v_hoje);
    IF v_n IN (7, 30, 60, 90, 365, 548, 730, 913) THEN
      INSERT INTO trofeus (usuario_id, tipo, marco, nome, descricao, execucao_id)
      VALUES (a.usuario_id, 'ofensiva', v_n,
              'Ofensiva: ' || CASE v_n WHEN 7 THEN 'primeira semana' WHEN 365 THEN '1 ano' WHEN 548 THEN '1 ano e meio'
                                       WHEN 730 THEN '2 anos' WHEN 913 THEN '2 anos e meio' ELSE v_n || ' dias' END,
              'Dias seguidos concluindo ao menos uma tarefa: ' || v_n || '.', v_exec.id)
      ON CONFLICT DO NOTHING RETURNING id INTO v_id;
      IF v_id IS NOT NULL THEN v_novos := v_novos || v_id; v_id := NULL; END IF;
    END IF;
  END IF;

  -- RN10 novo hábito: a cada 5 conclusões no mesmo âmbito
  SELECT count(*) INTO v_n FROM execucoes
   WHERE usuario_id = a.usuario_id AND ambito_id = a.ambito_id AND status = 'concluida';
  IF v_n % 5 = 0 THEN
    INSERT INTO trofeus (usuario_id, tipo, marco, ambito_id, nome, descricao, execucao_id)
    SELECT a.usuario_id, 'novo_habito', v_n, a.ambito_id, 'Novo hábito: ' || am.nome,
           v_n || ' atividades de ' || am.nome || ' concluídas.', v_exec.id
      FROM ambitos am WHERE am.id = a.ambito_id
    ON CONFLICT DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NOT NULL THEN v_novos := v_novos || v_id; v_id := NULL; END IF;
  END IF;

  -- RN11 frequência: a cada 30 conclusões da mesma atividade (mesmo título)
  SELECT count(*) INTO v_n FROM execucoes
   WHERE usuario_id = a.usuario_id AND lower(titulo) = lower(a.titulo) AND status = 'concluida';
  IF v_n % 30 = 0 THEN
    INSERT INTO trofeus (usuario_id, tipo, marco, titulo_atividade, nome, descricao, execucao_id)
    VALUES (a.usuario_id, 'frequencia', v_n, a.titulo, 'Frequência: ' || a.titulo,
            '"' || a.titulo || '" concluída ' || v_n || ' vezes.', v_exec.id)
    ON CONFLICT DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NOT NULL THEN v_novos := v_novos || v_id; END IF;
  END IF;

  RETURN QUERY SELECT v_pts, v_novos;
END $$;

-- UC26: compra de relatório. Confere saldo (RN15), impede duas compras ativas
-- do mesmo tipo e grava a expiração de 3 dias (RN24). Os números (dados) são
-- preenchidos em seguida pelo servidor.
CREATE FUNCTION comprar_relatorio(p_usuario uuid, p_tipo varchar) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE t tipos_relatorio; v_saldo int; v_tz text; v_hoje date; v_ini date; v_fim date; v_id uuid;
BEGIN
  SELECT * INTO t FROM tipos_relatorio WHERE codigo = p_tipo;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tipo de relatório inexistente.'; END IF;
  SELECT moedas, fuso_horario INTO v_saldo, v_tz FROM usuarios WHERE id = p_usuario FOR UPDATE;
  IF v_saldo < t.preco_moedas THEN
    RAISE EXCEPTION 'Saldo insuficiente: faltam % moedas.', t.preco_moedas - v_saldo;
  END IF;
  IF EXISTS (SELECT 1 FROM relatorios WHERE usuario_id = p_usuario AND tipo = p_tipo AND expira_em > now()) THEN
    RAISE EXCEPTION 'Já existe um relatório deste tipo disponível.';
  END IF;

  v_hoje := (now() AT TIME ZONE v_tz)::date;
  SELECT CASE p_tipo WHEN 'semanal' THEN v_hoje - 6 WHEN 'raiox' THEN v_hoje - 30
                     WHEN 'ranking' THEN v_hoje ELSE date_trunc('month', v_hoje)::date END,
         CASE p_tipo WHEN 'raiox' THEN v_hoje - 1 ELSE v_hoje END
    INTO v_ini, v_fim;

  INSERT INTO relatorios (usuario_id, tipo, preco_pago, periodo_inicio, periodo_fim, expira_em)
  VALUES (p_usuario, p_tipo, t.preco_moedas, v_ini, v_fim, now() + t.validade)
  RETURNING id INTO v_id;
  INSERT INTO movimentacoes_moedas (usuario_id, valor, motivo, relatorio_id)
  VALUES (p_usuario, -t.preco_moedas, 'compra_relatorio', v_id);
  UPDATE usuarios SET moedas = moedas - t.preco_moedas WHERE id = p_usuario;
  RETURN v_id;
END $$;

-- Feed (UC21): publicações com autor e contagem de reações
CREATE VIEW vw_feed AS
SELECT p.id, p.tipo, p.criado_em, p.foto_url, p.resumo,
       u.nome_usuario, u.cor_perfil,
       CASE WHEN u.mostrar_nome THEN u.nome_completo END AS nome_exibido,
       e.titulo AS atividade, t.nome AS trofeu, t.tipo AS trofeu_tipo, r.tipo AS relatorio_tipo,
       (SELECT count(*) FROM reacoes x WHERE x.publicacao_id = p.id AND x.tipo = 'joia')    AS joias,
       (SELECT count(*) FROM reacoes x WHERE x.publicacao_id = p.id AND x.tipo = 'coracao') AS coracoes
  FROM publicacoes p
  JOIN usuarios u        ON u.id = p.usuario_id
  LEFT JOIN execucoes e  ON e.id = p.execucao_id
  LEFT JOIN trofeus t    ON t.id = p.trofeu_id
  LEFT JOIN relatorios r ON r.id = p.relatorio_id;

-- Busca de usuários (UC28, RN25): o nome real só entra na busca se estiver visível
CREATE FUNCTION buscar_usuarios(p_termo text) RETURNS SETOF usuarios LANGUAGE sql STABLE AS $$
  SELECT * FROM usuarios
   WHERE nome_usuario LIKE '%' || lower(ltrim(p_termo, '@')) || '%'
      OR (mostrar_nome AND nome_completo ILIKE '%' || p_termo || '%')
   ORDER BY (nome_usuario LIKE lower(ltrim(p_termo, '@')) || '%') DESC, nome_usuario
   LIMIT 20
$$;

-- =====================================================================
--  DADOS INICIAIS
-- =====================================================================
INSERT INTO ambitos (nome, descricao, cor, icone) VALUES
  ('Saúde',               'Remédios diários, consultas, exames e cuidados com o corpo.', '#E5707E', 'health'),
  ('Estudos',             'Aulas, leituras, revisões, provas e trabalhos.',              '#4F86E8', 'book'),
  ('Autodesenvolvimento', 'Meditação, journaling, idiomas e novas habilidades.',          '#9277DB', 'sprout'),
  ('Esportes',            'Treinos, academia, corridas e alongamentos.',                  '#2FA67E', 'dumbbell'),
  ('Lazer',               'Hobbies, passeios, filmes e tempo com quem você gosta.',       '#EE9B3A', 'game'),
  ('Higiene',             'Banho, dentes, skincare e autocuidado.',                       '#27B3CC', 'drop'),
  ('Organização diária',  'Arrumar a cama, a casa e planejar o dia.',                     '#6B7FA3', 'list');

INSERT INTO tipos_relatorio (codigo, nome, descricao, preco_moedas, usa_ia, ordem) VALUES
  ('semanal',   'Retrospectiva semanal',     'Repetições, novidades e horas por âmbito nos últimos 7 dias.',          150, false, 1),
  ('raiox',     'Raio-X da rotina',          'Planejado x cumprido em 30 dias, dias e períodos mais produtivos.',    200, false, 2),
  ('ranking',   'Ranking entre amigos',      'Posição entre quem você segue: pontos, dias seguidos e troféus.',     250, false, 3),
  ('mensal',    'Retrospectiva mensal',      'Atividades por âmbito, troféus, interações e horas no mês.',          300, false, 4),
  ('detalhado', 'Mensal detalhado com IA',   'O mensal mais 5 atividades sugeridas e ideias de hábitos e hobbies.', 500, true,  5);