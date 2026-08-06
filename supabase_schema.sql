-- ==========================================
-- FILA DO ENERGÉTICO - SCHEMA SUPABASE (POSTGRESQL)
-- Execute este script no SQL Editor do Supabase
-- ==========================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. TABELAS DE CONFIGURAÇÃO E DADOS

CREATE TABLE IF NOT EXISTS configuracoes (
    chave TEXT PRIMARY KEY,
    valor TEXT NOT NULL,
    atualizado_em TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pessoas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nome TEXT UNIQUE NOT NULL,
    ordem INT NOT NULL DEFAULT 1,
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em TIMESTAMPTZ DEFAULT NOW(),
    senha_hash TEXT,
    senha_salt TEXT,
    pausado BOOLEAN NOT NULL DEFAULT FALSE,
    codigo_ativacao_hash TEXT
);

CREATE TABLE IF NOT EXISTS historico (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    data TIMESTAMPTZ DEFAULT NOW(),
    tipo TEXT NOT NULL,
    texto TEXT NOT NULL,
    pagador TEXT,
    ator TEXT,
    detalhes JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS votacoes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status TEXT NOT NULL DEFAULT 'ABERTA', -- ABERTA, APROVADA, REJEITADA, CANCELADA
    criado_em TIMESTAMPTZ DEFAULT NOW(),
    encerrado_em TIMESTAMPTZ,
    resultado TEXT,
    motivo TEXT NOT NULL,
    elegiveis JSONB DEFAULT '[]'::jsonb,
    criado_por TEXT
);

CREATE TABLE IF NOT EXISTS votos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    votacao_id UUID REFERENCES votacoes(id) ON DELETE CASCADE,
    pessoa TEXT NOT NULL,
    voto TEXT NOT NULL, -- sim, nao
    data TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(votacao_id, pessoa)
);

CREATE TABLE IF NOT EXISTS pendencias (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo TEXT NOT NULL, -- Pagamento obrigatorio de sexta-feira, Compra extra aprovada
    status TEXT NOT NULL DEFAULT 'PENDENTE', -- PENDENTE, CONFIRMADO, CANCELADO
    origem TEXT,
    data_chave TEXT,
    criado_em TIMESTAMPTZ DEFAULT NOW(),
    confirmado_em TIMESTAMPTZ,
    observacao TEXT,
    valor NUMERIC(10, 2) DEFAULT 17.50,
    metodo TEXT,
    comprovante TEXT,
    confirmado_por TEXT
);

CREATE TABLE IF NOT EXISTS movimentacoes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo TEXT NOT NULL,
    pessoa TEXT NOT NULL,
    data TIMESTAMPTZ DEFAULT NOW(),
    desfeito BOOLEAN DEFAULT FALSE,
    detalhes JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS compras (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    data DATE DEFAULT CURRENT_DATE,
    quantidade NUMERIC NOT NULL DEFAULT 1,
    nome TEXT NOT NULL,
    registrado_por TEXT,
    criado_em TIMESTAMPTZ DEFAULT NOW()
);

-- Insere configurações padrão se não existirem (senha de admin criptografada em sha256)
INSERT INTO configuracoes (chave, valor) VALUES
    ('admin_password', encode(digest('admin123', 'sha256'), 'hex')),
    ('unit_price', '17.50'),
    ('unit_liters', '2.00')
ON CONFLICT (chave) DO NOTHING;

-- 2. HABILITAR REALTIME DO SUPABASE
ALTER PUBLICATION supabase_realtime ADD TABLE pessoas, historico, votacoes, votos, pendencias, compras;

-- 3. FUNÇÕES AUXILIARES

CREATE OR REPLACE FUNCTION fn_hash(p_input TEXT) RETURNS TEXT SECURITY DEFINER AS $$
BEGIN
    RETURN encode(digest(p_input, 'sha256'), 'hex');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_generate_activation_code() RETURNS TEXT SECURITY DEFINER AS $$
DECLARE
    v_code TEXT;
BEGIN
    v_code := lpad(floor(random() * 900000 + 100000)::text, 6, '0');
    RETURN v_code;
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 4. FUNÇÃO PARA RETORNAR O ESTADO COMPLETO (getState)

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

    -- Votação ativa
    SELECT * INTO v_active_vote FROM votacoes WHERE status = 'ABERTA' ORDER BY criado_em DESC LIMIT 1;
    IF FOUND THEN
        -- Auto-finalizar se já passaram 15 minutos desde a criação
        IF v_active_vote.criado_em <= (now() - INTERVAL '15 minutes') THEN
            PERFORM fn_finish_vote();
            v_active_vote := NULL;
            v_votacao := NULL;
        ELSE
            SELECT count(*) INTO v_sim_count FROM votos WHERE votacao_id = v_active_vote.id AND voto = 'sim';
            SELECT count(*) INTO v_nao_count FROM votos WHERE votacao_id = v_active_vote.id AND voto = 'nao';
            SELECT coalesce(jsonb_agg(pessoa), '[]'::jsonb) INTO v_votantes FROM votos WHERE votacao_id = v_active_vote.id;
            
            v_elegiveis_count := jsonb_array_length(v_active_vote.elegiveis);
            v_maioria := floor(v_elegiveis_count / 2) + 1;

            IF p_session_person IS NOT NULL THEN
                SELECT voto INTO v_voto_usuario FROM votos WHERE votacao_id = v_active_vote.id AND pessoa = p_session_person;
            END IF;

            v_encerrar_em := to_char((v_active_vote.criado_em + INTERVAL '15 minutes') AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS');

            v_votacao := jsonb_build_object(
                'id', v_active_vote.id,
                'motivo', v_active_vote.motivo,
                'criadoPor', v_active_vote.criado_por,
                'criadoEm', to_char(v_active_vote.criado_em AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI:SS'),
                'encerraEm', v_encerrar_em,
                'encerraEmIso', to_char((v_active_vote.criado_em + INTERVAL '15 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
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

-- 5. FUNÇÕES DE AUTENTICAÇÃO

CREATE OR REPLACE FUNCTION fn_login_participant(p_nome TEXT, p_senha TEXT, p_codigo TEXT DEFAULT '') RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_person RECORD;
    v_clean_senha TEXT := trim(p_senha);
    v_clean_codigo TEXT := trim(p_codigo);
    v_salt TEXT;
    v_hash TEXT;
    v_activation_code TEXT := NULL;
BEGIN
    SELECT * INTO v_person FROM pessoas WHERE lower(nome) = lower(trim(p_nome));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Participante não encontrado. Peça para o admin cadastrar seu nome.';
    END IF;

    IF NOT v_person.ativo THEN
        RAISE EXCEPTION 'Participante removido da lista.';
    END IF;

    IF v_clean_senha = '' THEN
        RAISE EXCEPTION 'Digite sua senha.';
    END IF;

    IF v_person.senha_hash IS NULL OR v_person.senha_hash = '' THEN
        IF v_person.codigo_ativacao_hash IS NOT NULL AND v_person.codigo_ativacao_hash != '' THEN
            IF v_person.codigo_ativacao_hash != fn_hash(v_clean_codigo) THEN
                RAISE EXCEPTION 'Código de primeiro acesso incorreto.';
            END IF;
        END IF;

        v_salt := gen_random_uuid()::text;
        v_hash := fn_hash(v_salt || ':' || v_clean_senha);

        UPDATE pessoas SET senha_hash = v_hash, senha_salt = v_salt, codigo_ativacao_hash = NULL WHERE id = v_person.id;
        
        INSERT INTO historico (tipo, texto, ator, pagador)
        VALUES ('senha', v_person.nome || ' cadastrou a senha de acesso.', v_person.nome, v_person.nome);
    ELSE
        IF v_person.senha_salt IS NOT NULL AND v_person.senha_salt != '' THEN
            v_hash := fn_hash(v_person.senha_salt || ':' || v_clean_senha);
        ELSE
            v_hash := fn_hash(v_clean_senha);
        END IF;

        IF v_person.senha_hash != v_hash THEN
            RAISE EXCEPTION 'Senha incorreta.';
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'session', jsonb_build_object('tipo', 'participante', 'nome', v_person.nome, 'token', gen_random_uuid()::text),
        'state', fn_get_state(v_person.nome)
    );
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_login_admin(p_admin_senha TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_config_pwd TEXT;
BEGIN
    SELECT valor INTO v_config_pwd FROM configuracoes WHERE chave = 'admin_password';
    IF p_admin_senha != v_config_pwd AND fn_hash(p_admin_senha) != v_config_pwd THEN
        RAISE EXCEPTION 'Senha administrativa incorreta.';
    END IF;

    RETURN jsonb_build_object(
        'session', jsonb_build_object('tipo', 'admin', 'nome', 'Admin', 'token', gen_random_uuid()::text),
        'state', fn_get_state('Admin')
    );
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 6. OPERAÇÕES DE GERENCIAMENTO DA FILA

CREATE OR REPLACE FUNCTION fn_add_person(p_nome TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_clean_nome TEXT := trim(p_nome);
    v_person RECORD;
    v_max_ordem INT;
    v_code TEXT;
    v_state JSONB;
BEGIN
    IF v_clean_nome = '' THEN
        RAISE EXCEPTION 'Digite o nome da pessoa.';
    END IF;

    SELECT * INTO v_person FROM pessoas WHERE lower(nome) = lower(v_clean_nome);
    SELECT coalesce(max(ordem), 0) INTO v_max_ordem FROM pessoas WHERE ativo = TRUE;

    v_code := fn_generate_activation_code();

    IF v_person.id IS NOT NULL THEN
        IF v_person.ativo THEN
            RAISE EXCEPTION 'Essa pessoa já está na fila.';
        END IF;

        UPDATE pessoas SET
            ordem = v_max_ordem + 1,
            ativo = TRUE,
            senha_hash = NULL,
            senha_salt = NULL,
            pausado = FALSE,
            codigo_ativacao_hash = fn_hash(v_code)
        WHERE id = v_person.id;

        INSERT INTO historico (tipo, texto, ator, pagador)
        VALUES ('entrada', v_clean_nome || ' voltou para a lista e foi colocado no final da fila.', 'Admin', v_clean_nome);
    ELSE
        INSERT INTO pessoas (nome, ordem, ativo, codigo_ativacao_hash)
        VALUES (v_clean_nome, v_max_ordem + 1, TRUE, fn_hash(v_code));

        INSERT INTO historico (tipo, texto, ator, pagador)
        VALUES ('entrada', v_clean_nome || ' entrou na lista e foi colocado no final da fila.', 'Admin', v_clean_nome);
    END IF;

    v_state := fn_get_state('Admin');
    v_state := jsonb_set(v_state, '{meta,codigoAtivacao}', to_jsonb(v_code));
    v_state := jsonb_set(v_state, '{meta,codigoNome}', to_jsonb(v_clean_nome));
    RETURN v_state;
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_remove_person(p_nome TEXT) RETURNS JSONB SECURITY DEFINER AS $$
BEGIN
    UPDATE pessoas SET ativo = FALSE WHERE lower(nome) = lower(trim(p_nome));
    INSERT INTO historico (tipo, texto, ator, pagador)
    VALUES ('remocao', trim(p_nome) || ' foi removido da lista pelo admin.', 'Admin', trim(p_nome));
    RETURN fn_get_state('Admin');
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_toggle_pause(p_nome TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_pausado BOOLEAN;
BEGIN
    SELECT pausado INTO v_pausado FROM pessoas WHERE lower(nome) = lower(trim(p_nome)) AND ativo = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Participante não encontrado.';
    END IF;

    UPDATE pessoas SET pausado = NOT v_pausado WHERE lower(nome) = lower(trim(p_nome));
    INSERT INTO historico (tipo, texto, ator, pagador)
    VALUES ('ajuste', trim(p_nome) || CASE WHEN NOT v_pausado THEN ' foi pausado na fila.' ELSE ' retornou a fila.' END, 'Admin', trim(p_nome));

    RETURN fn_get_state('Admin');
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_reset_access(p_nome TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_clean_nome TEXT := trim(p_nome);
    v_code TEXT;
    v_state JSONB;
BEGIN
    v_code := fn_generate_activation_code();
    UPDATE pessoas SET senha_hash = NULL, senha_salt = NULL, codigo_ativacao_hash = fn_hash(v_code)
    WHERE lower(nome) = lower(v_clean_nome) AND ativo = TRUE;

    INSERT INTO historico (tipo, texto, ator, pagador)
    VALUES ('ajuste', 'Novo código de acesso gerado para ' || v_clean_nome, 'Admin', v_clean_nome);

    v_state := fn_get_state('Admin');
    v_state := jsonb_set(v_state, '{meta,codigoAtivacao}', to_jsonb(v_code));
    v_state := jsonb_set(v_state, '{meta,codigoNome}', to_jsonb(v_clean_nome));
    RETURN v_state;
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_set_next_person(p_nome TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_selected RECORD;
    v_max_ordem INT;
BEGIN
    SELECT * INTO v_selected FROM pessoas WHERE lower(nome) = lower(trim(p_nome)) AND ativo = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Participante não encontrado.';
    END IF;
    IF v_selected.pausado THEN
        RAISE EXCEPTION 'Retome o participante antes de colocá-lo no início da fila.';
    END IF;

    -- Define a ordem para 0 temporariamente
    UPDATE pessoas SET ordem = 0 WHERE id = v_selected.id;

    -- Reordena os outros
    WITH reordered AS (
        SELECT id, row_number() over (ORDER BY ordem ASC, criado_em ASC) AS new_ordem
        FROM pessoas WHERE ativo = TRUE
    )
    UPDATE pessoas p SET ordem = r.new_ordem FROM reordered r WHERE p.id = r.id;

    INSERT INTO historico (tipo, texto, ator, pagador)
    VALUES ('fila', v_selected.nome || ' foi selecionado pelo admin como próximo da fila.', 'Admin', v_selected.nome);

    RETURN fn_get_state('Admin');
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 7. OPERAÇÕES DE VOTAÇÃO

CREATE OR REPLACE FUNCTION fn_create_vote(p_motivo TEXT, p_criado_por TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_clean_motivo TEXT := trim(p_motivo);
    v_open INT;
    v_elegiveis JSONB;
BEGIN
    IF v_clean_motivo = '' THEN
        RAISE EXCEPTION 'Digite o motivo da votação.';
    END IF;

    SELECT count(*) INTO v_open FROM votacoes WHERE status = 'ABERTA';
    IF v_open > 0 THEN
        RAISE EXCEPTION 'Já existe uma votação aberta.';
    END IF;

    SELECT coalesce(jsonb_agg(nome), '[]'::jsonb) INTO v_elegiveis FROM pessoas WHERE ativo = TRUE;

    INSERT INTO votacoes (motivo, criado_por, elegiveis, status)
    VALUES (v_clean_motivo, p_criado_por, v_elegiveis, 'ABERTA');

    INSERT INTO historico (tipo, texto, ator)
    VALUES ('votacao', p_criado_por || ' abriu a votação: ' || v_clean_motivo, p_criado_por);

    RETURN fn_get_state(p_criado_por);
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_cast_vote(p_votacao_id UUID, p_pessoa TEXT, p_voto TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_vote_rec RECORD;
    v_existing INT;
BEGIN
    SELECT * INTO v_vote_rec FROM votacoes WHERE id = p_votacao_id AND status = 'ABERTA';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Votação não está mais aberta.';
    END IF;

    IF v_vote_rec.criado_em <= (now() - INTERVAL '15 minutes') THEN
        PERFORM fn_finish_vote();
        RAISE EXCEPTION 'Votação expirou e foi encerrada.';
    END IF;

    INSERT INTO votos (votacao_id, pessoa, voto)
    VALUES (p_votacao_id, p_pessoa, lower(trim(p_voto)))
    ON CONFLICT (votacao_id, pessoa) DO UPDATE SET voto = EXCLUDED.voto;

    INSERT INTO historico (tipo, texto, ator)
    VALUES ('votacao', p_pessoa || ' votou ' || upper(trim(p_voto)) || ' na votação: ' || v_vote_rec.motivo, p_pessoa);

    RETURN fn_get_state(p_pessoa);
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_finish_vote() RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_vote_rec RECORD;
    v_sim_count INT;
    v_nao_count INT;
    v_total_elegiveis INT;
    v_maioria INT;
    v_resultado TEXT;
BEGIN
    SELECT * INTO v_vote_rec FROM votacoes WHERE status = 'ABERTA' ORDER BY criado_em DESC LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Nenhuma votação aberta para finalizar.';
    END IF;

    SELECT count(*) INTO v_sim_count FROM votos WHERE votacao_id = v_vote_rec.id AND voto = 'sim';
    SELECT count(*) INTO v_nao_count FROM votos WHERE votacao_id = v_vote_rec.id AND voto = 'nao';
    v_total_elegiveis := jsonb_array_length(v_vote_rec.elegiveis);
    v_maioria := floor(v_total_elegiveis / 2) + 1;

    IF v_sim_count >= v_maioria THEN
        v_resultado := 'APROVADA';
    ELSE
        v_resultado := 'REJEITADA';
    END IF;

    UPDATE votacoes SET status = v_resultado, encerrado_em = now(), resultado = v_resultado WHERE id = v_vote_rec.id;

    IF v_resultado = 'APROVADA' THEN
        INSERT INTO pendencias (tipo, origem, observacao, status)
        VALUES ('Compra extra aprovada', 'votacao', v_vote_rec.motivo, 'PENDENTE');

        INSERT INTO historico (tipo, texto, ator)
        VALUES ('votacao', 'Votação "' || v_vote_rec.motivo || '" foi APROVADA (' || v_sim_count || ' a ' || v_nao_count || '). Pagamento gerado.', 'Admin');
    ELSE
        INSERT INTO historico (tipo, texto, ator)
        VALUES ('votacao', 'Votação "' || v_vote_rec.motivo || '" foi REJEITADA (' || v_sim_count || ' a ' || v_nao_count || ').', 'Admin');
    END IF;

    RETURN fn_get_state('Admin');
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_cancel_vote(p_admin_nome TEXT) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_vote_rec RECORD;
BEGIN
    SELECT * INTO v_vote_rec FROM votacoes WHERE status = 'ABERTA' ORDER BY criado_em DESC LIMIT 1;
    IF FOUND THEN
        UPDATE votacoes SET status = 'CANCELADA', encerrado_em = now(), resultado = 'CANCELADA' WHERE id = v_vote_rec.id;
        INSERT INTO historico (tipo, texto, ator)
        VALUES ('votacao', 'Votação "' || v_vote_rec.motivo || '" foi cancelada pelo admin.', p_admin_nome);
    END IF;

    RETURN fn_get_state(p_admin_nome);
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 8. CONFIRMAÇÃO DE PAGAMENTO E ROTAÇÃO DA FILA

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
BEGIN
    -- Seleciona a próxima pessoa da fila (não pausada)
    SELECT * INTO v_next_person FROM pessoas WHERE ativo = TRUE AND pausado = FALSE ORDER BY ordem ASC LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Nenhum participante ativo e disponível na fila.';
    END IF;

    -- Seleciona a pendência aberta
    SELECT * INTO v_pending FROM pendencias WHERE status = 'PENDENTE' ORDER BY criado_em DESC LIMIT 1;

    -- Salva movimentação para suporte a Undo
    INSERT INTO movimentacoes (tipo, pessoa, detalhes)
    VALUES ('compra', v_next_person.nome, jsonb_build_object(
        'ordemAnterior', v_next_person.ordem,
        'pendenciaId', CASE WHEN v_pending.id IS NOT NULL THEN v_pending.id::text ELSE NULL END
    ));

    -- Atualiza a pendência se houver
    IF v_pending.id IS NOT NULL THEN
        UPDATE pendencias SET
            status = 'CONFIRMADO',
            confirmado_em = now(),
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

    INSERT INTO historico (tipo, texto, pagador, ator, detalhes)
    VALUES (
        'pagamento',
        v_next_person.nome || ' realizou o pagamento do energético (R$ ' || p_valor::text || ') e foi para o final da fila.',
        v_next_person.nome,
        p_confirmado_por,
        jsonb_build_object('metodo', p_metodo, 'comprovante', p_comprovante, 'valor', p_valor)
    );

    RETURN fn_get_state(p_confirmado_por);
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_register_purchase(
    p_nome TEXT,
    p_quantidade NUMERIC DEFAULT 1,
    p_ator TEXT DEFAULT 'Admin'
) RETURNS JSONB SECURITY DEFINER AS $$
DECLARE
    v_clean_nome TEXT := trim(p_nome);
    v_person RECORD;
    v_max_ordem INT;
BEGIN
    SELECT * INTO v_person FROM pessoas WHERE lower(nome) = lower(v_clean_nome) AND ativo = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Participante não encontrado.';
    END IF;

    INSERT INTO compras (nome, quantidade, registrado_por, data)
    VALUES (v_person.nome, p_quantidade, p_ator, (now() AT TIME ZONE 'America/Sao_Paulo')::date);


    SELECT max(ordem) INTO v_max_ordem FROM pessoas WHERE ativo = TRUE;
    UPDATE pessoas SET ordem = v_max_ordem + 1 WHERE id = v_person.id;

    INSERT INTO historico (tipo, texto, pagador, ator)
    VALUES (
        'compra',
        v_person.nome || ' comprou ' || p_quantidade::text || ' energético(s) e foi para o final da fila.',
        v_person.nome,
        p_ator
    );

    RETURN fn_get_state(p_ator);
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

    -- Se tinha pendência vinculada, volta para PENDENTE
    IF v_mov.detalhes->>'pendenciaId' IS NOT NULL THEN
        UPDATE pendencias SET status = 'PENDENTE', confirmado_em = NULL WHERE id = (v_mov.detalhes->>'pendenciaId')::uuid;
    END IF;

    UPDATE movimentacoes SET desfeito = TRUE WHERE id = v_mov.id;

    INSERT INTO historico (tipo, texto, ator)
    VALUES ('ajuste', 'A última compra de ' || v_mov.pessoa || ' foi desfeita por ' || p_admin_nome || '.', p_admin_nome);

    RETURN fn_get_state(p_admin_nome);
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION fn_clear_all() RETURNS JSONB SECURITY DEFINER AS $$
BEGIN
    TRUNCATE TABLE compras, movimentacoes, pendencias, votos, votacoes, historico, pessoas RESTART IDENTITY CASCADE;
    RETURN fn_get_state('Admin');
END;
$$ LANGUAGE plpgsql VOLATILE;

-- ==========================================
-- 7. PERMISSÕES, RLS E SECURITY DEFINER (SEGURA CONTRA ESCRITA E LEITURA DIRETA)
-- ==========================================
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;

-- Habilita RLS em todas as tabelas
ALTER TABLE configuracoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE pessoas ENABLE ROW LEVEL SECURITY;
ALTER TABLE historico ENABLE ROW LEVEL SECURITY;
ALTER TABLE votacoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE votos ENABLE ROW LEVEL SECURITY;
ALTER TABLE pendencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimentacoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE compras ENABLE ROW LEVEL SECURITY;

-- Limpa políticas legadas se existirem
DROP POLICY IF EXISTS "anon_all_configuracoes" ON configuracoes;
DROP POLICY IF EXISTS "anon_all_pessoas" ON pessoas;
DROP POLICY IF EXISTS "anon_all_historico" ON historico;
DROP POLICY IF EXISTS "anon_all_votacoes" ON votacoes;
DROP POLICY IF EXISTS "anon_all_votos" ON votos;
DROP POLICY IF EXISTS "anon_all_pendencias" ON pendencias;
DROP POLICY IF EXISTS "anon_all_movimentacoes" ON movimentacoes;
DROP POLICY IF EXISTS "anon_all_compras" ON compras;

-- Políticas Seguras: Leitura pública para tabelas operacionais (necessário para Realtime WebSockets)
-- Nenhuma política de INSERT/UPDATE/DELETE direta para anon/authenticated (força uso de RPCs SECURITY DEFINER)
CREATE POLICY "read_pessoas" ON pessoas FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "read_historico" ON historico FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "read_votacoes" ON votacoes FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "read_votos" ON votos FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "read_pendencias" ON pendencias FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "read_movimentacoes" ON movimentacoes FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "read_compras" ON compras FOR SELECT TO anon, authenticated USING (true);

-- A tabela configuracoes NÃO possui leitura direta por REST (somente via RPC SECURITY DEFINER)

-- 8. ÍNDICES DE ALTA PERFORMANCE
-- ==========================================
CREATE INDEX IF NOT EXISTS idx_historico_data ON historico(data DESC);
CREATE INDEX IF NOT EXISTS idx_votos_votacao_id ON votos(votacao_id);
CREATE INDEX IF NOT EXISTS idx_votacoes_status ON votacoes(status);
CREATE INDEX IF NOT EXISTS idx_compras_data ON compras(data DESC);
CREATE INDEX IF NOT EXISTS idx_pessoas_ordem ON pessoas(ordem ASC);
CREATE INDEX IF NOT EXISTS idx_pendencias_status ON pendencias(status);

-- 9. AUTOMAÇÃO DE SEXTA-FEIRA (OPCIONAL VIA PG_CRON SUPABASE)
-- ==========================================
-- Para ativar a criação automática de pendências no Supabase toda sexta às 08:00:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule(
--     'pendencia_sexta_feira_08am',
--     '0 8 * * 5',
--     $$ INSERT INTO pendencias (tipo, origem, observacao, status, valor)
--        VALUES ('Pagamento obrigatório de sexta-feira', 'automatico', 'Gerado automaticamente toda sexta-feira', 'PENDENTE', 17.50); $$
-- );


