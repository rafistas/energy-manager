"""
Script de Migração de Dados: Google Sheets / Apps Script JSON -> Supabase SQL

Instruções:
1. No seu Google Apps Script ou planilha antiga, faça o download/export do JSON do estado (ou exporte as abas como CSV).
2. Cole o JSON exportado neste arquivo ou passe o caminho do arquivo JSON.
3. Execute: python migrate_data.py
4. O script gerará o arquivo `import_dados.sql` com todos os INSERTS prontos para rodar no Supabase!
"""

import json
import sys

def generate_sql(data):
    sql = []
    sql.append("-- ==========================================")
    sql.append("-- MIGRAÇÃO DE DADOS: GOOGLE SHEETS -> SUPABASE")
    sql.append("-- ==========================================\n")

    # 1. Pessoas
    pessoas = data.get("pessoas", [])
    if pessoas:
        sql.append("-- 1. Inserir Pessoas")
        for p in pessoas:
            nome = str(p.get("nome", "")).replace("'", "''")
            ordem = p.get("ordem", 1)
            pausado = "TRUE" if p.get("pausado") else "FALSE"
            senha_hash = f"'{p.get('senhaHash')}'" if p.get("senhaHash") else "NULL"
            senha_salt = f"'{p.get('senhaSalt')}'" if p.get("senhaSalt") else "NULL"
            codigo_hash = f"'{p.get('codigoAtivacaoHash')}'" if p.get("codigoAtivacaoHash") else "NULL"
            sql.append(
                f"INSERT INTO pessoas (nome, ordem, ativo, pausado, senha_hash, senha_salt, codigo_ativacao_hash) "
                f"VALUES ('{nome}', {ordem}, TRUE, {pausado}, {senha_hash}, {senha_salt}, {codigo_hash}) "
                f"ON CONFLICT (nome) DO UPDATE SET ordem = EXCLUDED.ordem, pausado = EXCLUDED.pausado;"
            )
        sql.append("")

    # 2. Histórico
    historico = data.get("historico", [])
    if historico:
        sql.append("-- 2. Inserir Histórico")
        for h in historico:
            texto = str(h.get("texto", "")).replace("'", "''")
            tipo = str(h.get("tipo", "geral")).replace("'", "''")
            ator = f"'{str(h.get('ator', '')).replace('\'', '\'\'')}'" if h.get("ator") else "NULL"
            pagador = f"'{str(h.get('pagador', '')).replace('\'', '\'\'')}'" if h.get("pagador") else "NULL"
            data_str = f"'{h.get('data')}'" if h.get("data") else "NOW()"
            sql.append(
                f"INSERT INTO historico (texto, tipo, ator, pagador, data) "
                f"VALUES ('{texto}', '{tipo}', {ator}, {pagador}, COALESCE(to_timestamp({data_str}, 'DD/MM/YYYY HH24:MI:SS'), NOW()));"
            )
        sql.append("")

    # 3. Compras
    compras = data.get("meta", {}).get("compras", {}).get("registros", [])
    if compras:
        sql.append("-- 3. Inserir Compras")
        for c in compras:
            nome = str(c.get("nome", "")).replace("'", "''")
            qtd = c.get("quantidade", 1)
            data_c = c.get("data", "CURRENT_DATE")
            sql.append(
                f"INSERT INTO compras (nome, quantidade, data) "
                f"VALUES ('{nome}', {qtd}, '{data_c}');"
            )
        sql.append("")

    return "\n".join(sql)

if __name__ == "__main__":
    sample_json_path = "export_data.json"
    try:
        with open(sample_json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        sql_content = generate_sql(data)
        with open("import_dados.sql", "w", encoding="utf-8") as f:
            f.write(sql_content)
        print("✅ Arquivo import_dados.sql gerado com sucesso!")
    except FileNotFoundError:
        print(f"⚠️ Crie um arquivo '{sample_json_path}' com os dados exportados do Apps Script para gerar o SQL de importação.")
