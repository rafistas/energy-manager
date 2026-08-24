-- Corrige votacoes que eram criadas com horario antigo ou fuso ambiguo.
-- Execute este arquivo uma vez no SQL Editor do Supabase.

ALTER TABLE public.votacoes
  ALTER COLUMN criado_em SET DEFAULT clock_timestamp();

CREATE OR REPLACE FUNCTION public.fn_set_vote_created_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- O horario deve ser definido no banco no instante do INSERT.
  NEW.criado_em := clock_timestamp();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_vote_created_at ON public.votacoes;

CREATE TRIGGER trg_set_vote_created_at
BEFORE INSERT ON public.votacoes
FOR EACH ROW
WHEN (NEW.status = 'ABERTA')
EXECUTE FUNCTION public.fn_set_vote_created_at();

-- Leitura independente da votacao ativa. Evita que uma versao antiga de
-- fn_get_state esconda uma votacao que continua ABERTA no banco.
CREATE OR REPLACE FUNCTION public.fn_get_active_vote(p_session_person TEXT DEFAULT NULL)
RETURNS JSONB
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  v_vote RECORD;
  v_vote_id UUID;
  v_sim_count INT;
  v_nao_count INT;
  v_voto_usuario TEXT := NULL;
  v_votantes JSONB;
BEGIN
  SELECT * INTO v_vote
  FROM public.votacoes
  WHERE status = 'ABERTA'
     OR (status = 'APROVADA' AND EXISTS (
       SELECT 1 FROM public.pendencias
       WHERE status = 'PENDENTE'
         AND origem = 'votacao'
         AND observacao = votacoes.motivo
     ))
  ORDER BY criado_em DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_vote.status = 'ABERTA'
     AND clock_timestamp() >= (v_vote.criado_em + INTERVAL '10 minutes') THEN
    v_vote_id := v_vote.id;
    PERFORM public.fn_finish_vote();

    SELECT * INTO v_vote
    FROM public.votacoes
    WHERE id = v_vote_id
      AND (status = 'ABERTA' OR (status = 'APROVADA' AND EXISTS (
        SELECT 1 FROM public.pendencias
        WHERE status = 'PENDENTE'
          AND origem = 'votacao'
          AND observacao = votacoes.motivo
      )));

    IF NOT FOUND THEN
      RETURN NULL;
    END IF;
  END IF;

  SELECT count(*) INTO v_sim_count FROM public.votos WHERE votacao_id = v_vote.id AND voto = 'sim';
  SELECT count(*) INTO v_nao_count FROM public.votos WHERE votacao_id = v_vote.id AND voto = 'nao';
  SELECT coalesce(jsonb_agg(pessoa), '[]'::jsonb) INTO v_votantes FROM public.votos WHERE votacao_id = v_vote.id;

  IF p_session_person IS NOT NULL THEN
    SELECT voto INTO v_voto_usuario FROM public.votos WHERE votacao_id = v_vote.id AND pessoa = p_session_person;
  END IF;

  RETURN jsonb_build_object(
    'id', v_vote.id,
    'status', v_vote.status,
    'motivo', v_vote.motivo,
    'criadoPor', v_vote.criado_por,
    'criadoEm', to_char(v_vote.criado_em AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
    'encerraEm', to_char((v_vote.criado_em + INTERVAL '10 minutes') AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
    'encerraEmIso', to_char((v_vote.criado_em + INTERVAL '10 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'sim', v_sim_count,
    'nao', v_nao_count,
    'total', coalesce(jsonb_array_length(v_vote.elegiveis), 0),
    'maioria', 4,
    'faltamParaAprovar', greatest(0, 4 - v_sim_count),
    'meuVoto', v_voto_usuario,
    'votantes', v_votantes
  );
END;
$$;

-- Centraliza a finalizacao e impede que chamadas automaticas encerrem cedo.
CREATE OR REPLACE FUNCTION public.fn_finish_vote_internal(p_force BOOLEAN DEFAULT FALSE)
RETURNS JSONB
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  v_vote_rec RECORD;
  v_sim_count INT;
  v_nao_count INT;
  v_resultado TEXT;
BEGIN
  SELECT * INTO v_vote_rec
  FROM public.votacoes
  WHERE status = 'ABERTA'
  ORDER BY criado_em DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN public.fn_get_state('Admin');
  END IF;

  IF NOT p_force
     AND clock_timestamp() < (v_vote_rec.criado_em + INTERVAL '10 minutes') THEN
    RETURN public.fn_get_state('Admin');
  END IF;

  SELECT count(*) INTO v_sim_count
  FROM public.votos
  WHERE votacao_id = v_vote_rec.id AND voto = 'sim';

  SELECT count(*) INTO v_nao_count
  FROM public.votos
  WHERE votacao_id = v_vote_rec.id AND voto = 'nao';

  v_resultado := CASE WHEN v_sim_count >= 4 THEN 'APROVADA' ELSE 'REJEITADA' END;

  UPDATE public.votacoes
  SET status = v_resultado,
      encerrado_em = clock_timestamp(),
      resultado = v_resultado
  WHERE id = v_vote_rec.id;

  IF v_resultado = 'APROVADA' THEN
    INSERT INTO public.pendencias (tipo, origem, observacao, status)
    SELECT 'Compra extra aprovada', 'votacao', v_vote_rec.motivo, 'PENDENTE'
    WHERE NOT EXISTS (
      SELECT 1 FROM public.pendencias
      WHERE origem = 'votacao'
        AND observacao IS NOT DISTINCT FROM v_vote_rec.motivo
        AND status IN ('PENDENTE', 'CONFIRMADO')
        AND criado_em >= v_vote_rec.criado_em
    )
    ON CONFLICT DO NOTHING;

    INSERT INTO public.historico (tipo, texto, ator)
    VALUES (
      'votacao',
      'Votação "' || v_vote_rec.motivo || '" foi APROVADA (' || v_sim_count || ' a ' || v_nao_count || '). Pagamento gerado.',
      'Admin'
    );
  ELSE
    INSERT INTO public.historico (tipo, texto, ator)
    VALUES (
      'votacao',
      'Votação "' || v_vote_rec.motivo || '" foi REJEITADA (' || v_sim_count || ' a ' || v_nao_count || ').',
      'Admin'
    );
  END IF;

  RETURN public.fn_get_state('Admin');
END;
$$;

-- Rotinas automaticas e chamadas antigas passam pela protecao de 10 minutos.
CREATE OR REPLACE FUNCTION public.fn_finish_vote()
RETURNS JSONB
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN public.fn_finish_vote_internal(FALSE);
END;
$$;

-- O botao manual do administrador pode encerrar antes do prazo.
CREATE OR REPLACE FUNCTION public.fn_finish_vote_admin()
RETURNS JSONB
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN public.fn_finish_vote_internal(TRUE);
END;
$$;

-- Remove o bloqueio visual causado por pendencias duplicadas ja pagas.
UPDATE public.pendencias p
SET status = 'CANCELADO'
WHERE p.status = 'PENDENTE'
  AND p.origem = 'votacao'
  AND EXISTS (
    SELECT 1 FROM public.pendencias c
    WHERE c.status = 'CONFIRMADO'
      AND c.origem = p.origem
      AND c.observacao IS NOT DISTINCT FROM p.observacao
      AND c.criado_em = p.criado_em
  );

CREATE UNIQUE INDEX IF NOT EXISTS uq_pendencia_votacao_aberta
ON public.pendencias ((coalesce(observacao, '')))
WHERE origem = 'votacao' AND status = 'PENDENTE';

-- Verificacao: deve retornar aproximadamente 600 segundos.
SELECT EXTRACT(EPOCH FROM (
  clock_timestamp() + INTERVAL '10 minutes' - clock_timestamp()
))::int AS duracao_votacao_segundos;
