# Fila do Energetico

Aplicacao compartilhada para controlar a ordem de compras, pagamentos e votacoes usando Google Sheets como base.

## Arquivos

- `index.html`: estrutura da interface.
- `styles.css`: identidade visual e responsividade.
- `app.js`: comportamento da tela e comunicacao com a API.
- `apps-script.gs`: backend ligado a planilha.
- `energy.html`: redirecionamento legado para `index.html`.

## Recursos

- fila com pausa temporaria e escolha manual do proximo;
- pagamento obrigatorio de sexta-feira;
- compra extra aprovada por votacao;
- contagem regressiva e maioria baseada nos elegiveis do inicio da votacao;
- valor, forma e referencia do comprovante;
- desfazer a ultima movimentacao;
- codigos seguros de primeiro acesso;
- sessoes temporarias sem salvar senhas no navegador;
- protecao contra operacoes repetidas;
- historico com ator e detalhes;
- backup manual e backup automatico antes da limpeza;
- manutencao automatica a cada 15 minutos.

## Publicar o backend

1. Abra o Apps Script ligado a planilha e substitua o codigo por `apps-script.gs`.
2. Salve e execute `setup` uma vez. Autorize planilhas, arquivos e acionadores quando solicitado.
3. Em `Configuracoes do projeto > Propriedades do script`, crie a propriedade `ADMIN_PASSWORD` com uma senha segura de pelo menos 8 caracteres.

4. Crie uma nova implantacao como `Aplicativo da Web`.
5. Configure `Executar como: Eu` e `Quem pode acessar: Qualquer pessoa com o link`.
6. Se a URL mudar, atualize `API_URL` no inicio de `app.js`.

As abas e colunas novas sao criadas por `setup` sem apagar os registros existentes. Senhas antigas sao atualizadas automaticamente para o formato com salt no proximo login.

## Publicar a interface

Publique juntos no Netlify:

```text
index.html
styles.css
app.js
```

Depois de publicar uma nova versao do Apps Script, recarregue a pagina e entre novamente. As sessoes da versao antiga nao contem o novo token.
