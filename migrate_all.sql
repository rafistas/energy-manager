-- ============================================================
-- MIGRAÇÃO CONSOLIDADA - ajustes desta rodada
--   * maioria da votação proporcional aos participantes (metade + 1)
--   * admin pode corrigir o dia de uma compra pelo card do calendário
--
-- Junta fix_vote_proportional_majority.sql + fix_purchase_date_edit.sql.
-- Pré-requisito: fix_vote_quantity.sql já aplicado (colunas quantidade/
-- confirmados em pendencias e função fn_energetico_label).
-- Seguro rodar mais de uma vez (tudo é CREATE OR REPLACE).
-- ============================================================

-- 1. Maioria simples proporcional aos participantes elegíveis: metade + 1
--    (9 participantes -> 5 votos "sim"; 10 -> 6).
CREATE OR REPLACE FUNCTION fn_vote_majority(p_total INT) RETURNS INT AS $$
    SELECT greatest(1, floor(coalesce(p_total, 0) / 2.0)::int + 1);
$$ LANGUAGE sql IMMUTABLE;

-- 2. Leitura da votação ativa (usa a maioria proporcional)
CREATE OR REPLACE FUNCTION fn_get_active_vote(p_session_person TEXT DEFAULT NULL) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_vote RECORD;
    v_vote_id UUID;
    v_sim_count INT;
    v_nao_count INT;
    v_total INT;
    v_maioria INT;
    v_voto_usuario TEXT := NULL;
    v_votantes JSONB;
BEGIN
    SELECT * INTO v_vote
    FROM votacoes
    WHERE status = 'ABERTA'
       OR (status = 'APROVADA' AND EXISTS (
           SELECT 1 FROM pendencias
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
        PERFORM fn_finish_vote();

        SELECT * INTO v_vote
        FROM votacoes
        WHERE id = v_vote_id
          AND (status = 'ABERTA' OR (status = 'APROVADA' AND EXISTS (
              SELECT 1 FROM pendencias
              WHERE status = 'PENDENTE'
                AND origem = 'votacao'
                AND observacao = votacoes.motivo
          )));

        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
    END IF;

    SELECT count(*) INTO v_sim_count FROM votos WHERE votacao_id = v_vote.id AND voto = 'sim';
    SELECT count(*) INTO v_nao_count FROM votos WHERE votacao_id = v_vote.id AND voto = 'nao';
    SELECT coalesce(jsonb_agg(pessoa), '[]'::jsonb) INTO v_votantes FROM votos WHERE votacao_id = v_vote.id;

    v_total := coalesce(jsonb_array_length(v_vote.elegiveis), 0);
    v_maioria := fn_vote_majority(v_total);

    IF p_session_person IS NOT NULL THEN
        SELECT voto INTO v_voto_usuario FROM votos WHERE votacao_id = v_vote.id AND pessoa = p_session_person;
    END IF;

    RETURN jsonb_build_object(
        'id', v_vote.id,
        'status', v_vote.status,
        'motivo', v_vote.motivo,
        'quantidade', greatest(1, coalesce(v_vote.quantidade, 1)),
        'criadoPor', v_vote.criado_por,
        'criadoEm', to_char(v_vote.criado_em AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
        'encerraEm', to_char((v_vote.criado_em + INTERVAL '10 minutes') AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
        'encerraEmIso', to_char((v_vote.criado_em + INTERVAL '10 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'sim', v_sim_count,
        'nao', v_nao_count,
        'total', v_total,
        'maioria', v_maioria,
        'faltamParaAprovar', greatest(0, v_maioria - v_sim_count),
        'meuVoto', v_voto_usuario,
        'votantes', v_votantes
    );
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 3. Estado completo (maioria proporcional + id de cada compra)
CREATE OR REPLACE FUNCTION fn_get_state(p_session_person TEXT DEFAULT NULL) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_pessoas JSONB;
    v_historico JSONB;
    v_votacao JSONB := NULL;
    v_pendencia JSONB := NULL;
    v_compras JSONB;
    v_active_vote RECORD;
    v_pending_rec RECORD;
    v_sim_count INT;
    v_nao_count INT;
    v_elegiveis_count INT;
    v_maioria INT;
    v_voto_usuario TEXT := NULL;
    v_votantes JSONB;
    v_encerrar_em TEXT;
    v_unit_price NUMERIC;
    v_unit_liters NUMERIC;
BEGIN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', id,
        'nome', nome,
        'ordem', ordem,
        'pausado', pausado,
        'hasPassword', (senha_hash IS NOT NULL AND senha_hash != '')
    ) ORDER BY ordem ASC), '[]'::jsonb)
    INTO v_pessoas
    FROM pessoas WHERE ativo = TRUE;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'data', to_char(data AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
        'tipo', tipo,
        'texto', texto,
        'pagador', pagador,
        'ator', ator,
        'detalhes', detalhes
    ) ORDER BY data DESC), '[]'::jsonb)
    INTO v_historico
    FROM (SELECT * FROM historico ORDER BY data DESC LIMIT 100) h;

    SELECT * INTO v_active_vote FROM votacoes
    WHERE status = 'ABERTA'
       OR (status = 'APROVADA' AND EXISTS (
           SELECT 1 FROM pendencias
           WHERE status = 'PENDENTE'
             AND origem = 'votacao'
             AND observacao = votacoes.motivo
       ))
    ORDER BY criado_em DESC LIMIT 1;

    IF FOUND THEN
        IF v_active_vote.status = 'ABERTA'
           AND clock_timestamp() >= (v_active_vote.criado_em + INTERVAL '10 minutes') THEN
            PERFORM fn_finish_vote();

            SELECT * INTO v_active_vote FROM votacoes
            WHERE status = 'APROVADA' AND id = v_active_vote.id AND EXISTS (
                SELECT 1 FROM pendencias
                WHERE status = 'PENDENTE'
                  AND origem = 'votacao'
                  AND observacao = votacoes.motivo
            );

            IF NOT FOUND THEN
                v_active_vote := NULL;
                v_votacao := NULL;
            END IF;
        END IF;

        IF v_active_vote IS NOT NULL THEN
            SELECT count(*) INTO v_sim_count FROM votos WHERE votacao_id = v_active_vote.id AND voto = 'sim';
            SELECT count(*) INTO v_nao_count FROM votos WHERE votacao_id = v_active_vote.id AND voto = 'nao';
            SELECT coalesce(jsonb_agg(pessoa), '[]'::jsonb) INTO v_votantes FROM votos WHERE votacao_id = v_active_vote.id;

            v_elegiveis_count := coalesce(jsonb_array_length(v_active_vote.elegiveis), 0);
            v_maioria := fn_vote_majority(v_elegiveis_count);

            IF p_session_person IS NOT NULL THEN
                SELECT voto INTO v_voto_usuario FROM votos WHERE votacao_id = v_active_vote.id AND pessoa = p_session_person;
            END IF;

            v_encerrar_em := to_char((v_active_vote.criado_em + INTERVAL '10 minutes') AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS');

            v_votacao := jsonb_build_object(
                'id', v_active_vote.id,
                'status', v_active_vote.status,
                'motivo', v_active_vote.motivo,
                'quantidade', greatest(1, coalesce(v_active_vote.quantidade, 1)),
                'criadoPor', v_active_vote.criado_por,
                'criadoEm', to_char(v_active_vote.criado_em AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
                'encerraEm', v_encerrar_em,
                'encerraEmIso', to_char((v_active_vote.criado_em + INTERVAL '10 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'sim', v_sim_count,
                'nao', v_nao_count,
                'total', v_elegiveis_count,
                'maioria', v_maioria,
                'faltamParaAprovar', greatest(0, v_maioria - v_sim_count),
                'meuVoto', v_voto_usuario,
                'votantes', v_votantes
            );
        END IF;
    END IF;

    SELECT * INTO v_pending_rec FROM pendencias WHERE status = 'PENDENTE' ORDER BY criado_em DESC LIMIT 1;
    IF FOUND THEN
        v_pendencia := jsonb_build_object(
            'id', v_pending_rec.id,
            'tipo', v_pending_rec.tipo,
            'observacao', v_pending_rec.observacao,
            'valor', v_pending_rec.valor,
            'quantidade', greatest(1, coalesce(v_pending_rec.quantidade, 1)),
            'confirmados', greatest(0, coalesce(v_pending_rec.confirmados, 0)),
            'restantes', greatest(0, greatest(1, coalesce(v_pending_rec.quantidade, 1)) - coalesce(v_pending_rec.confirmados, 0)),
            'criadoEm', to_char(v_pending_rec.criado_em AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS')
        );
    END IF;

    SELECT valor::numeric INTO v_unit_price FROM configuracoes WHERE chave = 'unit_price';
    SELECT valor::numeric INTO v_unit_liters FROM configuracoes WHERE chave = 'unit_liters';

    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', id,
        'data', to_char(data, 'YYYY-MM-DD'),
        'quantidade', quantidade,
        'nome', nome
    ) ORDER BY data DESC), '[]'::jsonb)
    INTO v_compras
    FROM (SELECT * FROM compras ORDER BY data DESC LIMIT 500) c;

    RETURN jsonb_build_object(
        'pessoas', v_pessoas,
        'historico', v_historico,
        'votacao', v_votacao,
        'pagamentoPendente', v_pendencia,
        'meta', jsonb_build_object(
            'atualizadoEm', to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
            'compras', jsonb_build_object(
                'precoUnitario', coalesce(v_unit_price, 17.50),
                'litrosPorUnidade', coalesce(v_unit_liters, 2.00),
                'registros', v_compras
            )
        )
    );
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 4. Finalização da votação (aprova com a maioria proporcional)
CREATE OR REPLACE FUNCTION fn_finish_vote_internal(p_force BOOLEAN DEFAULT FALSE) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_vote_rec RECORD;
    v_sim_count INT;
    v_nao_count INT;
    v_total_elegiveis INT;
    v_maioria INT;
    v_resultado TEXT;
    v_quantidade INT := 1;
BEGIN
    SELECT * INTO v_vote_rec
    FROM votacoes
    WHERE status = 'ABERTA'
    ORDER BY criado_em DESC
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN fn_get_state('Admin');
    END IF;

    IF NOT p_force AND clock_timestamp() < (v_vote_rec.criado_em + INTERVAL '10 minutes') THEN
        RETURN fn_get_state('Admin');
    END IF;

    SELECT count(*) INTO v_sim_count FROM votos WHERE votacao_id = v_vote_rec.id AND voto = 'sim';
    SELECT count(*) INTO v_nao_count FROM votos WHERE votacao_id = v_vote_rec.id AND voto = 'nao';
    v_total_elegiveis := coalesce(jsonb_array_length(v_vote_rec.elegiveis), 0);
    v_maioria := fn_vote_majority(v_total_elegiveis);
    v_quantidade := greatest(1, coalesce(v_vote_rec.quantidade, 1));

    IF v_sim_count >= v_maioria THEN
        v_resultado := 'APROVADA';
    ELSE
        v_resultado := 'REJEITADA';
    END IF;

    UPDATE votacoes SET status = v_resultado, encerrado_em = now(), resultado = v_resultado WHERE id = v_vote_rec.id;

    IF v_resultado = 'APROVADA' THEN
        INSERT INTO pendencias (tipo, origem, observacao, status, quantidade, confirmados)
        SELECT 'Compra extra aprovada', 'votacao', v_vote_rec.motivo, 'PENDENTE', v_quantidade, 0
        WHERE NOT EXISTS (
            SELECT 1 FROM pendencias
            WHERE origem = 'votacao'
              AND observacao IS NOT DISTINCT FROM v_vote_rec.motivo
              AND status IN ('PENDENTE', 'CONFIRMADO')
              AND criado_em >= v_vote_rec.criado_em
        )
        ON CONFLICT DO NOTHING;

        INSERT INTO historico (tipo, texto, ator)
        VALUES ('votacao', 'Votação "' || v_vote_rec.motivo || '" foi APROVADA (' || v_sim_count || ' a ' || v_nao_count || '). Pagamento de ' || v_quantidade || fn_energetico_label(v_quantidade) || ' gerado.', 'Admin');
    ELSE
        INSERT INTO historico (tipo, texto, ator)
        VALUES ('votacao', 'Votação "' || v_vote_rec.motivo || '" foi REJEITADA (' || v_sim_count || ' a ' || v_nao_count || ').', 'Admin');
    END IF;

    RETURN fn_get_state('Admin');
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 5. Ajuste administrativo da data de uma compra
CREATE OR REPLACE FUNCTION fn_update_purchase_date(p_id UUID, p_data DATE, p_ator TEXT DEFAULT 'Admin') RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_compra RECORD;
    v_old_data DATE;
    v_today DATE := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
    v_hist_id UUID;
    v_match_count INT;
BEGIN
    IF p_data IS NULL THEN
        RAISE EXCEPTION 'Escolha uma data válida.';
    END IF;

    IF p_data > v_today THEN
        RAISE EXCEPTION 'A data não pode estar no futuro.';
    END IF;

    SELECT * INTO v_compra FROM compras WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compra não encontrada.';
    END IF;

    v_old_data := v_compra.data;
    IF v_old_data IS NOT DISTINCT FROM p_data THEN
        RETURN fn_get_state(p_ator);
    END IF;

    UPDATE compras SET data = p_data WHERE id = p_id;

    SELECT count(*) INTO v_match_count
    FROM historico
    WHERE tipo IN ('pagamento', 'compra')
      AND lower(pagador) = lower(v_compra.nome)
      AND (data AT TIME ZONE 'America/Sao_Paulo')::date = v_old_data;

    IF v_match_count = 1 THEN
        SELECT id INTO v_hist_id
        FROM historico
        WHERE tipo IN ('pagamento', 'compra')
          AND lower(pagador) = lower(v_compra.nome)
          AND (data AT TIME ZONE 'America/Sao_Paulo')::date = v_old_data;

        UPDATE historico
        SET data = (p_data + (data AT TIME ZONE 'America/Sao_Paulo')::time) AT TIME ZONE 'America/Sao_Paulo'
        WHERE id = v_hist_id;
    END IF;

    INSERT INTO historico (tipo, texto, pagador, ator)
    VALUES (
        'ajuste',
        'A data da compra de ' || v_compra.nome || ' foi movida de '
          || to_char(v_old_data, 'DD/MM/YYYY') || ' para ' || to_char(p_data, 'DD/MM/YYYY') || ' por ' || p_ator || '.',
        v_compra.nome,
        p_ator
    );

    RETURN fn_get_state(p_ator);
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 6. Permissões e recarga do cache do PostgREST
GRANT EXECUTE ON FUNCTION public.fn_vote_majority(INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_update_purchase_date(UUID, DATE, TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
