-- Votacao de 1 ou 2 energeticos.
-- Ao abrir a votacao o autor escolhe a quantidade: com 1 apenas o proximo da fila
-- paga; com 2 os dois proximos pagam (um pagamento de cada vez).
-- Execute este arquivo uma vez no SQL Editor do Supabase.

-- 1. COLUNAS NOVAS
ALTER TABLE public.votacoes   ADD COLUMN IF NOT EXISTS quantidade  INT NOT NULL DEFAULT 1;
ALTER TABLE public.pendencias ADD COLUMN IF NOT EXISTS quantidade  INT NOT NULL DEFAULT 1;
ALTER TABLE public.pendencias ADD COLUMN IF NOT EXISTS confirmados INT NOT NULL DEFAULT 0;

-- Pendencias ja confirmadas antes desta versao contam como 1 pagamento feito.
UPDATE public.pendencias SET confirmados = 1 WHERE status = 'CONFIRMADO' AND confirmados = 0;

-- 2. FUNCOES
CREATE OR REPLACE FUNCTION fn_energetico_label(p_quantidade INT) RETURNS TEXT AS $$
BEGIN
    RETURN CASE WHEN coalesce(p_quantidade, 1) > 1 THEN ' energéticos' ELSE ' energético' END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_get_active_vote(p_session_person TEXT DEFAULT NULL) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_vote RECORD;
    v_vote_id UUID;
    v_sim_count INT;
    v_nao_count INT;
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
        'total', coalesce(jsonb_array_length(v_vote.elegiveis), 0),
        'maioria', 4,
        'faltamParaAprovar', greatest(0, 4 - v_sim_count),
        'meuVoto', v_voto_usuario,
        'votantes', v_votantes
    );
END;
$$ LANGUAGE plpgsql VOLATILE;

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
    -- Pessoas ativas ordenadas
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', id,
        'nome', nome,
        'ordem', ordem,
        'pausado', pausado,
        'hasPassword', (senha_hash IS NOT NULL AND senha_hash != '')
    ) ORDER BY ordem ASC), '[]'::jsonb)
    INTO v_pessoas
    FROM pessoas WHERE ativo = TRUE;

    -- Histórico recente (últimos 100 registros)
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

    -- Votação ativa ou recentemente aprovada aguardando pagamento
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
        -- A votação permanece aberta por até 10 minutos, independentemente da contagem.
        IF v_active_vote.status = 'ABERTA'
           AND clock_timestamp() >= (v_active_vote.criado_em + INTERVAL '10 minutes') THEN
            PERFORM fn_finish_vote();
            
            -- Tenta recuperar caso tenha sido aprovada e gerado pendência
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
            
            v_elegiveis_count := jsonb_array_length(v_active_vote.elegiveis);
            v_maioria := 4;

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

    -- Pagamento pendente ativo
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

    -- Estatísticas de Compras
    SELECT valor::numeric INTO v_unit_price FROM configuracoes WHERE chave = 'unit_price';
    SELECT valor::numeric INTO v_unit_liters FROM configuracoes WHERE chave = 'unit_liters';

    SELECT coalesce(jsonb_agg(jsonb_build_object(
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

-- A assinatura antiga (sem quantidade) e removida para evitar ambiguidade no PostgREST.
DROP FUNCTION IF EXISTS fn_create_vote(TEXT, TEXT);

CREATE OR REPLACE FUNCTION fn_create_vote(p_motivo TEXT, p_criado_por TEXT, p_quantidade INT DEFAULT 1) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_clean_motivo TEXT := trim(p_motivo);
    v_open INT;
    v_elegiveis JSONB;
    v_quantidade INT := coalesce(p_quantidade, 1);
BEGIN
    IF v_clean_motivo = '' THEN
        RAISE EXCEPTION 'Digite o motivo da votação.';
    END IF;

    IF v_quantidade NOT IN (1, 2) THEN
        RAISE EXCEPTION 'A votação deve ser de 1 ou 2 energéticos.';
    END IF;

    SELECT count(*) INTO v_open FROM votacoes WHERE status = 'ABERTA';
    IF v_open > 0 THEN
        RAISE EXCEPTION 'Já existe uma votação aberta.';
    END IF;

    SELECT coalesce(jsonb_agg(nome), '[]'::jsonb) INTO v_elegiveis FROM pessoas WHERE ativo = TRUE;

    -- Define o horario explicitamente para nao depender de defaults antigos da tabela.
    INSERT INTO votacoes (motivo, criado_por, elegiveis, status, criado_em, quantidade)
    VALUES (v_clean_motivo, p_criado_por, v_elegiveis, 'ABERTA', clock_timestamp(), v_quantidade);

    INSERT INTO historico (tipo, texto, ator)
    VALUES ('votacao', p_criado_por || ' abriu a votação de ' || v_quantidade || fn_energetico_label(v_quantidade) || ': ' || v_clean_motivo, p_criado_por);

    RETURN fn_get_state(p_criado_por);
END;
$$ LANGUAGE plpgsql VOLATILE;

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
    -- O bloqueio impede que varios clientes finalizem e gerem pendencias duplicadas.
    SELECT * INTO v_vote_rec
    FROM votacoes
    WHERE status = 'ABERTA'
    ORDER BY criado_em DESC
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN fn_get_state('Admin');
    END IF;

    -- Chamadas automaticas nunca podem encerrar uma votacao antes do prazo.
    IF NOT p_force AND clock_timestamp() < (v_vote_rec.criado_em + INTERVAL '10 minutes') THEN
        RETURN fn_get_state('Admin');
    END IF;

    SELECT count(*) INTO v_sim_count FROM votos WHERE votacao_id = v_vote_rec.id AND voto = 'sim';
    SELECT count(*) INTO v_nao_count FROM votos WHERE votacao_id = v_vote_rec.id AND voto = 'nao';
    v_total_elegiveis := jsonb_array_length(v_vote_rec.elegiveis);
    v_maioria := 4;
    v_quantidade := greatest(1, coalesce(v_vote_rec.quantidade, 1));

    IF v_sim_count >= 4 OR v_sim_count >= v_maioria THEN
        v_resultado := 'APROVADA';
    ELSE
        v_resultado := 'REJEITADA';
    END IF;

    UPDATE votacoes SET status = v_resultado, encerrado_em = now(), resultado = v_resultado WHERE id = v_vote_rec.id;

    IF v_resultado = 'APROVADA' THEN
        -- A pendencia guarda quantos pagamentos a votacao aprovou (1 ou 2).
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

CREATE OR REPLACE FUNCTION fn_confirm_payment(
    p_metodo TEXT DEFAULT 'PIX',
    p_comprovante TEXT DEFAULT '',
    p_valor NUMERIC DEFAULT 17.50,
    p_confirmado_por TEXT DEFAULT 'Admin'
) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_pending RECORD;
    v_next_person RECORD;
    v_max_ordem INT;
    v_quantidade INT := 1;
    v_confirmados_antes INT := 0;
    v_confirmados INT := 0;
    v_restantes INT := 0;
    v_texto TEXT;
BEGIN
    -- Serializa as confirmacoes. Sem isso dois admins confirmando ao mesmo tempo
    -- leem a fila antes da rotacao e cobram a mesma pessoa duas vezes.
    PERFORM pg_advisory_xact_lock(hashtext('energy_manager_confirmar_pagamento')::bigint);

    -- Seleciona a próxima pessoa da fila (não pausada)
    SELECT * INTO v_next_person FROM pessoas WHERE ativo = TRUE AND pausado = FALSE ORDER BY ordem ASC LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Nenhum participante ativo e disponível na fila.';
    END IF;

    -- Seleciona a pendência aberta. O bloqueio evita duas confirmações simultâneas.
    SELECT * INTO v_pending FROM pendencias WHERE status = 'PENDENTE' ORDER BY criado_em DESC LIMIT 1 FOR UPDATE;

    IF v_pending.id IS NOT NULL THEN
        v_quantidade := greatest(1, coalesce(v_pending.quantidade, 1));
        v_confirmados_antes := greatest(0, coalesce(v_pending.confirmados, 0));
    END IF;

    -- Salva movimentação para suporte a Undo
    INSERT INTO movimentacoes (tipo, pessoa, detalhes)
    VALUES ('compra', v_next_person.nome, jsonb_build_object(
        'ordemAnterior', v_next_person.ordem,
        'pendenciaId', CASE WHEN v_pending.id IS NOT NULL THEN v_pending.id::text ELSE NULL END,
        'confirmadosAnterior', v_confirmados_antes
    ));

    -- Atualiza a pendência se houver. Com quantidade 2 ela só fecha no segundo pagamento.
    IF v_pending.id IS NOT NULL THEN
        v_confirmados := v_confirmados_antes + 1;
        v_restantes := greatest(0, v_quantidade - v_confirmados);

        UPDATE pendencias SET
            confirmados = v_confirmados,
            status = CASE WHEN v_restantes = 0 THEN 'CONFIRMADO' ELSE 'PENDENTE' END,
            confirmado_em = CASE WHEN v_restantes = 0 THEN now() ELSE NULL END,
            metodo = p_metodo,
            comprovante = p_comprovante,
            valor = p_valor,
            confirmado_por = p_confirmado_por
        WHERE id = v_pending.id;
    END IF;

    -- Registra a compra para estatísticas
    INSERT INTO compras (nome, quantidade, registrado_por, data)
    VALUES (v_next_person.nome, 1, p_confirmado_por, (now() AT TIME ZONE 'America/Sao_Paulo')::date);

    -- Rotaciona a pessoa para o final da fila
    SELECT max(ordem) INTO v_max_ordem FROM pessoas WHERE ativo = TRUE;
    UPDATE pessoas SET ordem = v_max_ordem + 1 WHERE id = v_next_person.id;

    IF v_quantidade > 1 THEN
        v_texto := v_next_person.nome || ' realizou o pagamento ' || v_confirmados || ' de ' || v_quantidade
                   || ' (R$ ' || p_valor::text || ') e foi para o final da fila.';
    ELSE
        v_texto := v_next_person.nome || ' realizou o pagamento do energético (R$ ' || p_valor::text || ') e foi para o final da fila.';
    END IF;

    INSERT INTO historico (tipo, texto, pagador, ator, detalhes)
    VALUES (
        'pagamento',
        v_texto,
        v_next_person.nome,
        p_confirmado_por,
        jsonb_build_object(
            'metodo', p_metodo,
            'comprovante', p_comprovante,
            'valor', p_valor,
            'quantidade', v_quantidade,
            'pagamento', v_confirmados,
            'restantes', v_restantes
        )
    );

    RETURN fn_get_state(p_confirmado_por);
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_undo_last_purchase(p_admin_nome TEXT DEFAULT 'Admin') RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_mov RECORD;
    v_compra RECORD;
    v_person RECORD;
BEGIN
    SELECT * INTO v_mov FROM movimentacoes WHERE desfeito = FALSE ORDER BY data DESC LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Nenhuma movimentação recente para desfazer.';
    END IF;

    SELECT * INTO v_person FROM pessoas WHERE lower(nome) = lower(v_mov.pessoa) AND ativo = TRUE;
    IF FOUND THEN
        -- Coloca no início da fila (ordem 0 e reordena)
        UPDATE pessoas SET ordem = 0 WHERE id = v_person.id;
        WITH reordered AS (
            SELECT id, row_number() over (ORDER BY ordem ASC, criado_em ASC) AS new_ordem
            FROM pessoas WHERE ativo = TRUE
        )
        UPDATE pessoas p SET ordem = r.new_ordem FROM reordered r WHERE p.id = r.id;
    END IF;

    -- Remove a última compra registrada para essa pessoa
    SELECT id INTO v_compra FROM compras WHERE lower(nome) = lower(v_mov.pessoa) ORDER BY criado_em DESC LIMIT 1;
    IF v_compra.id IS NOT NULL THEN
        DELETE FROM compras WHERE id = v_compra.id;
    END IF;

    -- Se tinha pendência vinculada, volta para PENDENTE com o contador anterior
    IF v_mov.detalhes->>'pendenciaId' IS NOT NULL THEN
        UPDATE pendencias SET
            status = 'PENDENTE',
            confirmado_em = NULL,
            confirmados = greatest(0, coalesce((v_mov.detalhes->>'confirmadosAnterior')::int, 0))
        WHERE id = (v_mov.detalhes->>'pendenciaId')::uuid;
    END IF;

    UPDATE movimentacoes SET desfeito = TRUE WHERE id = v_mov.id;

    INSERT INTO historico (tipo, texto, ator)
    VALUES ('ajuste', 'A última compra de ' || v_mov.pessoa || ' foi desfeita por ' || p_admin_nome || '.', p_admin_nome);

    RETURN fn_get_state(p_admin_nome);
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 3. PERMISSOES E RECARGA DO CACHE DO POSTGREST
GRANT EXECUTE ON FUNCTION public.fn_energetico_label(INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_create_vote(TEXT, TEXT, INT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
