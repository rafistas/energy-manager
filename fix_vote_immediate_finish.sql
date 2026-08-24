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
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nenhuma votação aberta para finalizar.';
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
    VALUES ('Compra extra aprovada', 'votacao', v_vote_rec.motivo, 'PENDENTE');

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

-- Verificacao: deve retornar aproximadamente 600 segundos.
SELECT EXTRACT(EPOCH FROM (
  clock_timestamp() + INTERVAL '10 minutes' - clock_timestamp()
))::int AS duracao_votacao_segundos;
