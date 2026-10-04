-- =====================================================================
--  LifeQuest - MIGRAÇÃO 1: integração com o Supabase
--  Rode UMA vez, no SQL Editor, DEPOIS do lifequest-banco.sql.
--  O que faz: liga usuarios ao login do Supabase, ativa a segurança
--  por linha (RLS), protege pontos e moedas, restringe as funções
--  sensíveis e cria as funções que o app chama (RPC).
--  ATENÇÃO: apaga os usuários de teste criados à mão (ex.: ana.teste).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Usuários passam a ser as contas do login do Supabase (auth.users)
-- ---------------------------------------------------------------------
DELETE FROM public.usuarios;  -- remove dados de teste sem login

ALTER TABLE public.usuarios DROP COLUMN senha_hash;   -- senha fica no Supabase Auth
ALTER TABLE public.usuarios DROP COLUMN email;        -- e-mail também (auth.users.email)
ALTER TABLE public.usuarios ALTER COLUMN id DROP DEFAULT;
ALTER TABLE public.usuarios
  ADD CONSTRAINT usuarios_id_auth_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- Cria o perfil automaticamente no cadastro, com os dados enviados pelo app
CREATE FUNCTION public.fn_novo_usuario() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.usuarios (id, nome_usuario, nome_completo, data_nascimento, cor_perfil)
  VALUES (
    NEW.id,
    lower(NEW.raw_user_meta_data ->> 'nome_usuario'),
    COALESCE(NEW.raw_user_meta_data ->> 'nome_completo', ''),
    (NEW.raw_user_meta_data ->> 'data_nascimento')::date,
    COALESCE(NEW.raw_user_meta_data ->> 'cor_perfil', '#3D7BD9'));
  RETURN NEW;
END $$;

CREATE TRIGGER tg_novo_usuario
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.fn_novo_usuario();

-- ---------------------------------------------------------------------
-- 2. Perfil público: o que qualquer pessoa pode ver de outra.
--    A tabela usuarios fica privada (data de nascimento, nome oculto).
-- ---------------------------------------------------------------------
CREATE VIEW public.perfis AS
SELECT id, nome_usuario, cor_perfil, pontos,
       CASE WHEN mostrar_nome THEN nome_completo END AS nome_exibido,
       criado_em
  FROM public.usuarios;

-- A busca (UC28, RN25) passa a devolver perfis públicos
DROP FUNCTION public.buscar_usuarios(text);
CREATE FUNCTION public.buscar_usuarios(p_termo text) RETURNS SETOF public.perfis
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.* FROM public.perfis p
    JOIN public.usuarios u ON u.id = p.id
   WHERE u.nome_usuario LIKE '%' || lower(ltrim(p_termo, '@')) || '%'
      OR (u.mostrar_nome AND u.nome_completo ILIKE '%' || p_termo || '%')
   ORDER BY (u.nome_usuario LIKE lower(ltrim(p_termo, '@')) || '%') DESC, u.nome_usuario
   LIMIT 20
$$;

-- O cadastro pergunta se o @ está livre antes de criar a conta (RN01)
CREATE FUNCTION public.nome_usuario_disponivel(p_nome text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT lower(p_nome) ~ '^[a-z0-9._]{3,20}$'
     AND NOT EXISTS (SELECT 1 FROM public.usuarios WHERE nome_usuario = lower(p_nome))
$$;

-- Dias seguidos aparecem no perfil de qualquer pessoa: só devolve um número
ALTER FUNCTION public.dias_seguidos(uuid, date) SECURITY DEFINER SET search_path = public;
ALTER FUNCTION public.fn_checar_ambitos()       SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------
-- 3. Âmbitos salvos de uma vez, numa única transação (RN04, RN05)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.salvar_ambitos(p_itens jsonb) RETURNS void
LANGUAGE plpgsql SET search_path = public AS $$
-- p_itens = [{"ambito_id": "...", "prioritario": true}, ...]
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login.'; END IF;
  DELETE FROM usuario_ambitos ua
   WHERE ua.usuario_id = auth.uid()
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_itens) i
                      WHERE (i ->> 'ambito_id')::uuid = ua.ambito_id);
  INSERT INTO usuario_ambitos (usuario_id, ambito_id, prioritario)
  SELECT auth.uid(), (i ->> 'ambito_id')::uuid, COALESCE((i ->> 'prioritario')::boolean, false)
    FROM jsonb_array_elements(p_itens) i
  ON CONFLICT (usuario_id, ambito_id) DO UPDATE SET prioritario = EXCLUDED.prioritario;
END $$;

-- ---------------------------------------------------------------------
-- 4. Compra de relatório pelo próprio usuário logado (UC26)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.comprar_meu_relatorio(p_tipo varchar) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login.'; END IF;
  RETURN comprar_relatorio(auth.uid(), p_tipo);
END $$;

-- Exclusão da própria conta (UC25): apaga o login e, em cascata, todos os dados
CREATE FUNCTION public.excluir_minha_conta() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login.'; END IF;
  DELETE FROM auth.users WHERE id = auth.uid();
END $$;

-- ---------------------------------------------------------------------
-- 5. Quem pode executar cada função
--    Por padrão, qualquer um executa funções; aqui fechamos as sensíveis.
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;  -- o Worker usa este papel

GRANT EXECUTE ON FUNCTION public.nome_usuario_disponivel(text)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_usuarios(text)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.salvar_ambitos(jsonb)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.comprar_meu_relatorio(varchar)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.excluir_minha_conta()                TO authenticated;
GRANT EXECUTE ON FUNCTION public.agenda(uuid, date, date)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.ocorre_em(public.atividades, date)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.dias_seguidos(uuid, date)            TO authenticated;
-- registrar_conclusao e comprar_relatorio(uuid, ...) ficam SÓ para o servidor

-- ---------------------------------------------------------------------
-- 6. Pontos e moedas: o usuário não altera
-- ---------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON public.usuarios FROM anon, authenticated;
GRANT UPDATE (nome_usuario, nome_completo, cor_perfil, mostrar_nome, fuso_horario)
  ON public.usuarios TO authenticated;
GRANT SELECT ON public.perfis, public.vw_feed TO authenticated;

-- ---------------------------------------------------------------------
-- 7. Segurança por linha (RLS)
--    Com RLS ligado, uma linha só aparece/muda se alguma política permitir.
-- ---------------------------------------------------------------------
ALTER TABLE public.usuarios             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ambitos              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usuario_ambitos      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.atividades           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.atividade_lembretes  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.execucoes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.validacoes_foto      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trofeus              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seguidores           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tipos_relatorio      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.relatorios           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sugestoes_ia         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.publicacoes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reacoes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimentacoes_moedas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mensagens_suporte    ENABLE ROW LEVEL SECURITY;

-- usuarios: cada um vê e edita só o próprio cadastro completo
CREATE POLICY usuarios_ler_proprio   ON public.usuarios FOR SELECT TO authenticated USING (id = auth.uid());
CREATE POLICY usuarios_editar_proprio ON public.usuarios FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- ambitos: todos leem (perfis mostram os âmbitos); cada um gerencia os que criou
CREATE POLICY ambitos_ler    ON public.ambitos FOR SELECT TO authenticated USING (true);
CREATE POLICY ambitos_criar  ON public.ambitos FOR INSERT TO authenticated WITH CHECK (criado_por = auth.uid());
CREATE POLICY ambitos_editar ON public.ambitos FOR UPDATE TO authenticated USING (criado_por = auth.uid()) WITH CHECK (criado_por = auth.uid());

-- usuario_ambitos: todos leem; cada um altera os seus
CREATE POLICY ua_ler     ON public.usuario_ambitos FOR SELECT TO authenticated USING (true);
CREATE POLICY ua_inserir ON public.usuario_ambitos FOR INSERT TO authenticated WITH CHECK (usuario_id = auth.uid());
CREATE POLICY ua_editar  ON public.usuario_ambitos FOR UPDATE TO authenticated USING (usuario_id = auth.uid()) WITH CHECK (usuario_id = auth.uid());
CREATE POLICY ua_excluir ON public.usuario_ambitos FOR DELETE TO authenticated USING (usuario_id = auth.uid());

-- atividades e lembretes: totalmente privados
CREATE POLICY atividades_dono ON public.atividades FOR ALL TO authenticated
  USING (usuario_id = auth.uid()) WITH CHECK (usuario_id = auth.uid());
CREATE POLICY lembretes_dono ON public.atividade_lembretes FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.atividades a WHERE a.id = atividade_id AND a.usuario_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.atividades a WHERE a.id = atividade_id AND a.usuario_id = auth.uid()));

-- execucoes: o usuário inicia e adia, mas NUNCA marca como concluída nem dá pontos
CREATE POLICY execucoes_ler ON public.execucoes FOR SELECT TO authenticated USING (usuario_id = auth.uid());
CREATE POLICY execucoes_criar ON public.execucoes FOR INSERT TO authenticated
  WITH CHECK (usuario_id = auth.uid() AND status <> 'concluida' AND pontos IS NULL AND concluida_em IS NULL);
CREATE POLICY execucoes_editar ON public.execucoes FOR UPDATE TO authenticated
  USING (usuario_id = auth.uid() AND status <> 'concluida')
  WITH CHECK (usuario_id = auth.uid() AND status <> 'concluida' AND pontos IS NULL AND concluida_em IS NULL);

-- validações e extrato de moedas: só leitura do próprio (quem grava é o servidor)
CREATE POLICY validacoes_ler ON public.validacoes_foto FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.execucoes e WHERE e.id = execucao_id AND e.usuario_id = auth.uid()));
CREATE POLICY moedas_ler ON public.movimentacoes_moedas FOR SELECT TO authenticated USING (usuario_id = auth.uid());

-- troféus: públicos (RN21); quem cria é o servidor
CREATE POLICY trofeus_ler ON public.trofeus FOR SELECT TO authenticated USING (true);

-- seguidores: todos leem; cada um segue/deixa de seguir por si
CREATE POLICY seg_ler     ON public.seguidores FOR SELECT TO authenticated USING (true);
CREATE POLICY seg_seguir  ON public.seguidores FOR INSERT TO authenticated WITH CHECK (seguidor_id = auth.uid());
CREATE POLICY seg_deixar  ON public.seguidores FOR DELETE TO authenticated USING (seguidor_id = auth.uid());

-- relatórios: privados; criados só pela função de compra
CREATE POLICY tipos_ler       ON public.tipos_relatorio FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY relatorios_ler  ON public.relatorios FOR SELECT TO authenticated USING (usuario_id = auth.uid());
CREATE POLICY sugestoes_ler   ON public.sugestoes_ia FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.relatorios r WHERE r.id = relatorio_id AND r.usuario_id = auth.uid()));
CREATE POLICY sugestoes_decidir ON public.sugestoes_ia FOR UPDATE TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.relatorios r WHERE r.id = relatorio_id AND r.usuario_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.relatorios r WHERE r.id = relatorio_id AND r.usuario_id = auth.uid()));
REVOKE UPDATE ON public.sugestoes_ia FROM authenticated;
GRANT  UPDATE (status, atividade_id) ON public.sugestoes_ia TO authenticated;

-- publicações: públicas; cada um publica só o que é seu e apaga as suas (RN13, RN22)
CREATE POLICY pub_ler ON public.publicacoes FOR SELECT TO authenticated USING (true);
CREATE POLICY pub_criar ON public.publicacoes FOR INSERT TO authenticated WITH CHECK (
  usuario_id = auth.uid() AND (
    (execucao_id  IS NOT NULL AND EXISTS (SELECT 1 FROM public.execucoes  e WHERE e.id = execucao_id  AND e.usuario_id = auth.uid() AND e.status = 'concluida')) OR
    (trofeu_id    IS NOT NULL AND EXISTS (SELECT 1 FROM public.trofeus    t WHERE t.id = trofeu_id    AND t.usuario_id = auth.uid())) OR
    (relatorio_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.relatorios r WHERE r.id = relatorio_id AND r.usuario_id = auth.uid()))));
CREATE POLICY pub_excluir ON public.publicacoes FOR DELETE TO authenticated USING (usuario_id = auth.uid());

-- reações: todos leem; cada um dá e tira as suas (RN14)
CREATE POLICY reacao_ler    ON public.reacoes FOR SELECT TO authenticated USING (true);
CREATE POLICY reacao_dar    ON public.reacoes FOR INSERT TO authenticated WITH CHECK (usuario_id = auth.uid());
CREATE POLICY reacao_tirar  ON public.reacoes FOR DELETE TO authenticated USING (usuario_id = auth.uid());

-- suporte: o usuário só envia
CREATE POLICY suporte_enviar ON public.mensagens_suporte FOR INSERT TO authenticated WITH CHECK (usuario_id = auth.uid());

-- ---------------------------------------------------------------------
-- 8. Armazenamento das selfies (usado na etapa 4, pelo Worker)
--    Bucket público com nomes de arquivo impossíveis de adivinhar,
--    para as fotos compartilhadas aparecerem no feed.
-- ---------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public) VALUES ('comprovacoes', 'comprovacoes', true)
ON CONFLICT (id) DO NOTHING;