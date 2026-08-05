# Fila do Energético

Aplicação compartilhada para controlar a ordem de compras, pagamentos e votações com backend de altíssima performance no **Supabase (PostgreSQL + Realtime)**.

## ⚡ Recursos e Benefícios do Supabase

- **Sincronização em Tempo Real (WebSockets)**: Quando alguém vota, paga ou altera a fila, as telas de todos os participantes se atualizam **ao vivo** instantaneamente com indicador visual de conexão (`Ao vivo`, `Reconectando`, `Off-line`).
- **Resposta Instantânea (< 100ms)**: Fim do atraso de carregamento e *cold start*.
- **Controle de Fila**: Pausa temporária e escolha manual do próximo pagador.
- **Votações Coletivas**: Maioria calculada e medidor dinâmico de energia com encerramento automático em 15 minutos.
- **Dashboard e Estatísticas**: Gráficos de compras por participante e calendário mensal de consumo.
- **Segurança Avançada**:
  - Senhas de participantes criptografadas com `sha256` + `salt` único.
  - Senha de admin criptografada no banco.
  - Políticas de **Row Level Security (RLS)** restritivas no PostgreSQL (proteção contra chamadas diretas não autorizadas via REST API).
- **Índices de Performance**: Índices SQL otimizados em todas as colunas de filtro e ordenação (`data`, `status`, `votacao_id`, `ordem`).

---

## 🛠️ Como Configurar o Backend (Supabase)

1. Crie uma conta gratuita em [supabase.com](https://supabase.com) e crie um novo projeto.
2. No painel do seu projeto Supabase, acesse **SQL Editor**.
3. Copie todo o conteúdo do arquivo [`supabase_schema.sql`](file:///c:/Projects/energy-manager/supabase_schema.sql) deste repositório, cole no SQL Editor e clique em **Run**.
4. Acesse **Project Settings > API** e copie:
   - **Project URL** (`https://xxx.supabase.co`)
   - **anon / public key** (`eyJhbG...`)
5. Abra o arquivo [`netlify/app.js`](file:///c:/Projects/energy-manager/netlify/app.js) e cole as credenciais nas primeiras linhas:
   ```javascript
   const SUPABASE_URL = "https://SEU-PROJETO.supabase.co";
   const SUPABASE_ANON_KEY = "SUA_CHAVE_ANONIMA_AQUI";
   ```

---

## 🚀 Publicar a Interface (Netlify)

Publique os arquivos da pasta `netlify/` no Netlify:
- `index.html`
- `styles.css`
- `app.js`

Pronto! A aplicação estará no ar rodando com tempo real e resposta ultra rápida.

---

## 📂 Arquivos Legados

O código original do backend em Google Apps Script foi movido para a pasta [`legacy/apps-script.gs`](file:///c:/Projects/energy-manager/legacy/apps-script.gs) para fins de histórico. A versão ativa da aplicação utiliza o Supabase.
