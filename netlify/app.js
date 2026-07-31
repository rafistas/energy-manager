// Configuração do Supabase
const SUPABASE_URL = window.ENV_SUPABASE_URL || "https://gmmxgjtlvilowwcudypm.supabase.co";
const SUPABASE_ANON_KEY = window.ENV_SUPABASE_ANON_KEY || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUyNTU3ODAsImV4cCI6MjEwMDgzMTc4MH0.mAciU6FJGRHxCKIwuC6aRv4t0KGtiuvbX2kmM4M6oZI";


const SESSION_KEY = "energy_manager_session_v2";
const THEME_KEY = "energy_manager_theme";

// Inicialização do cliente Supabase
const supabaseClient = window.supabase ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;

let session = readSession(),
    state = { pessoas: [], historico: [], votacao: null, pagamentoPendente: null, meta: {} },
    activeTab = "fila",
    countdownTimer = null,
    refreshTimer = null,
    realtimeChannel = null,
    actionInFlight = false,
    purchasePeriod = "all",
    purchaseCalendarDate = new Date(new Date().getFullYear(), new Date().getMonth(), 1),
    lastEnergyLevel = null,
    lastVoteState = null;

const $ = id => document.getElementById(id);
const esc = value => String(value ?? "").replace(/[&<>'"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));
const icons = () => globalThis.lucide?.createIcons();

function applyTheme(theme = localStorage.getItem(THEME_KEY) || "dark") {
  document.documentElement.dataset.theme = theme;
  const button = $('themeBtn');
  if (button) {
    const dark = theme === "dark";
    button.title = dark ? "Usar modo claro" : "Usar modo escuro";
    button.innerHTML = `<i data-lucide="${dark ? "sun" : "moon"}"></i>`;
    icons();
  }
}
function toggleTheme() {
  const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  localStorage.setItem(THEME_KEY, next);
  applyTheme(next);
}

function readSession() {
  try {
    const value = JSON.parse(localStorage.getItem(SESSION_KEY) || "null");
    return value?.token ? value : null;
  } catch {
    return null;
  }
}

// Ponte de API executando RPCs no Supabase
async function api(action, payload = {}) {
  if (!supabaseClient || SUPABASE_URL.includes("SUA-INSTANCIA")) {
    throw new Error("Configure a SUPABASE_URL e SUPABASE_ANON_KEY no início do arquivo app.js");
  }

  let rpcName = "";
  let rpcParams = {};

  switch (action) {
    case "getState":
    case "state":
      rpcName = "fn_get_state";
      rpcParams = { p_session_person: session?.nome || null };
      break;
    case "loginParticipant":
      rpcName = "fn_login_participant";
      rpcParams = { p_nome: payload.nome, p_senha: payload.senha, p_codigo: payload.codigo || "" };
      break;
    case "loginAdmin":
      rpcName = "fn_login_admin";
      rpcParams = { p_admin_senha: payload.adminSenha };
      break;
    case "addPerson":
      rpcName = "fn_add_person";
      rpcParams = { p_nome: payload.nome };
      break;
    case "removePerson":
      rpcName = "fn_remove_person";
      rpcParams = { p_nome: payload.nome };
      break;
    case "togglePause":
      rpcName = "fn_toggle_pause";
      rpcParams = { p_nome: payload.nome };
      break;
    case "resetAccess":
      rpcName = "fn_reset_access";
      rpcParams = { p_nome: payload.nome };
      break;
    case "setNextPerson":
      rpcName = "fn_set_next_person";
      rpcParams = { p_nome: payload.nome };
      break;
    case "createVote":
      rpcName = "fn_create_vote";
      rpcParams = { p_motivo: payload.motivo || "Compra extra", p_criado_por: session?.nome || "Admin" };
      break;
    case "castVote":
      if (!state.votacao?.id) throw new Error("Nenhuma votação aberta.");
      rpcName = "fn_cast_vote";
      rpcParams = { p_votacao_id: state.votacao.id, p_pessoa: session?.nome, p_voto: payload.voto };
      break;
    case "finishVote":
      rpcName = "fn_finish_vote";
      rpcParams = {};
      break;
    case "cancelVote":
      rpcName = "fn_cancel_vote";
      rpcParams = { p_admin_nome: session?.nome || "Admin" };
      break;
    case "registerPurchase":
      rpcName = "fn_confirm_payment";
      rpcParams = {
        p_metodo: payload.metodo || "PIX",
        p_comprovante: payload.comprovante || "",
        p_valor: parseFloat(payload.valor || 17.50) || 17.50,
        p_confirmado_por: session?.nome || "Admin"
      };
      break;
    case "undoLastPurchase":
      rpcName = "fn_undo_last_purchase";
      rpcParams = { p_admin_nome: session?.nome || "Admin" };
      break;
    case "clearAll":
      rpcName = "fn_clear_all";
      rpcParams = {};
      break;
    default:
      throw new Error("Ação não reconhecida.");
  }

  const { data, error } = await supabaseClient.rpc(rpcName, rpcParams);

  if (error) {
    throw new Error(error.message || "Erro ao conectar com o banco de dados.");
  }

  return data;
}

function setBusy(button, busy) { setActionLoading(button, busy); }
function setActionLoading(button, busy) {
  if (!button) return;
  if (busy) {
    button.dataset.originalHtml = button.innerHTML;
    button.style.minWidth = `${button.offsetWidth}px`;
    button.disabled = true;
    button.classList.add("action-loading");
    button.innerHTML = button.classList.contains("icon-button") ? '<span class="button-spinner" aria-label="Carregando"></span>' : '<span class="button-spinner"></span><span>Aguarde...</span>';
  } else {
    button.disabled = false;
    button.classList.remove("action-loading");
    if (button.dataset.originalHtml) button.innerHTML = button.dataset.originalHtml;
    button.style.minWidth = "";
    delete button.dataset.originalHtml;
    icons();
  }
}

function toast(message, type = "success") {
  const item = document.createElement("div");
  item.className = `toast ${type}`;
  item.innerHTML = `<i data-lucide="${type === "error" ? "circle-alert" : "circle-check"}"></i><span>${esc(message)}</span>`;
  $('toastRegion').append(item);
  icons();
  setTimeout(() => item.remove(), 4200);
}

document.querySelectorAll('[data-login-tab]').forEach(button => button.addEventListener('click', () => {
  document.querySelectorAll('[data-login-tab]').forEach(item => item.classList.toggle('active', item === button));
  $('participantForm').classList.toggle('hidden', button.dataset.loginTab !== "participante");
  $('adminForm').classList.toggle('hidden', button.dataset.loginTab !== "admin");
  $('loginStatus').textContent = "";
}));

$('participantForm').addEventListener('submit', event => {
  event.preventDefault();
  login('loginParticipant', { nome: $('loginNome').value.trim(), senha: $('loginSenha').value, codigo: $('loginCodigo').value.trim() }, event.submitter);
});

$('adminForm').addEventListener('submit', event => {
  event.preventDefault();
  login('loginAdmin', { adminSenha: $('adminSenha').value }, event.submitter);
});

async function login(action, payload, button) {
  try {
    setBusy(button, true);
    $('loginStatus').textContent = "";
    const data = await api(action, payload);
    session = data.session;
    localStorage.setItem(SESSION_KEY, JSON.stringify(session));
    applyState(data.state);
    showApp();
    toast("Acesso liberado.");
  } catch (error) {
    $('loginStatus').textContent = error.message;
  } finally {
    setBusy(button, false);
  }
}

function showApp() {
  const logged = !!session;
  $('loginView').classList.toggle('hidden', logged);
  $('appView').classList.toggle('hidden', !logged);
  if (!logged) return;
  const admin = session.tipo === "admin";
  $('adminBtn').classList.toggle('hidden', !admin);
  $('addPersonBtn').classList.toggle('hidden', !admin);
  $('avatarText').textContent = (session.nome || "A").slice(0, 2).toUpperCase();
  startRealtime();
}

function logout(showMessage = false) {
  session = null;
  localStorage.removeItem(SESSION_KEY);
  if (realtimeChannel && supabaseClient) supabaseClient.removeChannel(realtimeChannel);
  clearInterval(countdownTimer);
  closeDrawer();
  showApp();
  if (showMessage) toast("Sua sessão expirou.", "error");
}

async function loadState(silent = false) {
  if (!session) return;
  try {
    if (!silent) setBusy($('refreshBtn'), true);
    const data = await api("getState");
    applyState(data);
    if (!silent) toast("Dados atualizados.");
  } catch (error) {
    if (!silent) toast(error.message, "error");
  } finally {
    setBusy($('refreshBtn'), false);
  }
}

function startRealtime() {
  if (!supabaseClient || realtimeChannel) return;
  loadState(true);

  // Escuta alterações em tempo real via WebSockets
  realtimeChannel = supabaseClient
    .channel('energy_manager_realtime')
    .on('postgres_changes', { event: '*', schema: 'public' }, () => {
      loadState(true);
    })
    .subscribe();
}

function applyState(data) {
  if (!data) return;
  state = {
    pessoas: data.pessoas || [],
    historico: data.historico || [],
    votacao: data.votacao || null,
    pagamentoPendente: data.pagamentoPendente || null,
    meta: data.meta || {}
  };
  render();
  if (state.meta.codigoAtivacao) showAccessCode(state.meta.codigoNome, state.meta.codigoAtivacao);
}

function render() {
  renderSpotlight();
  renderQueue();
  renderVote();
  renderPurchaseStats();
  renderPurchaseCalendar();
  renderHistory();
  renderAdmin();
  $('queueCount').textContent = state.pessoas.length;
  $('voteDot').classList.toggle('hidden', !state.votacao);
  $('syncLabel').textContent = state.meta.atualizadoEm ? `Ao vivo · ${state.meta.atualizadoEm}` : "";
  icons();
}

function renderSpotlight() {
  const pending = state.pagamentoPendente, next = state.pessoas.find(person => !person.pausado);
  $('nextPayer').textContent = next?.nome || "Fila vazia";
  $('spotlightKicker').textContent = pending ? "Pagamento pendente" : "Próximo a pagar";
  $('spotlightText').textContent = pending ? `${pending.tipo}${pending.observacao ? ` · ${pending.observacao}` : ""}` : "Fila pronta para a próxima compra.";
  const action = $('spotlightAction');
  const isAdmin = session?.tipo === "admin";
  action.classList.toggle('hidden', !isAdmin);
  if (isAdmin) {
    action.innerHTML = `<i data-lucide="circle-check"></i>${pending ? "Confirmar pagamento" : `Registrar compra (${esc(next?.nome || "Próximo")})`}`;
    action.onclick = openPaymentModal;
  }
}

function renderQueue() {
  const container = $('queueList'), admin = session?.tipo === "admin";
  if (!state.pessoas.length) {
    container.className = "empty-state";
    container.innerHTML = '<div><i data-lucide="users"></i><p>Nenhum participante na fila.</p></div>';
    return;
  }
  container.className = "queue-list";
  let activePosition = 0;
  container.innerHTML = state.pessoas.map(person => {
    if (!person.pausado) activePosition++;
    const isNext = !person.pausado && activePosition === 1;
    return `<article class="queue-row ${isNext ? "next" : ""} ${person.pausado ? "paused" : ""}"><span class="position">${person.pausado ? "–" : activePosition}</span><div><div class="person-name">${esc(person.nome)}</div><div class="person-meta">${isNext ? '<span class="status-pill green">Próximo</span>' : ""}${person.pausado ? '<span class="status-pill">Em pausa</span>' : ""}${!person.hasPassword ? '<span class="status-pill">Primeiro acesso</span>' : ""}</div></div>${admin ? `<div class="row-actions"><button class="icon-button" data-action="pause" data-name="${esc(person.nome)}" title="${person.pausado ? "Retomar" : "Pausar"}"><i data-lucide="${person.pausado ? "play" : "pause"}"></i></button><button class="icon-button" data-action="access" data-name="${esc(person.nome)}" title="Gerar novo acesso"><i data-lucide="key-round"></i></button><button class="icon-button" data-action="remove" data-name="${esc(person.nome)}" title="Remover"><i data-lucide="user-minus"></i></button></div>` : ""}</article>`;
  }).join("");
  container.querySelectorAll('[data-action]').forEach(button => button.onclick = () => queueAction(button.dataset.action, button.dataset.name, button));
}

async function queueAction(action, name, button) {
  if (action === "pause") return execute("togglePause", { nome: name }, "Fila atualizada.", button);
  if (action === "access") return confirmAction("Gerar novo acesso", `A senha atual de ${name} será removida e um novo código será criado.`, confirmButton => execute("resetAccess", { nome: name }, "Novo acesso gerado.", confirmButton));
  confirmAction("Remover participante", `${name} será removido da fila. O histórico será preservado.`, confirmButton => execute("removePerson", { nome: name }, "Participante removido.", confirmButton), true);
}

function renderVote() {
  clearInterval(countdownTimer);
  const container = $('voteContent'), vote = state.votacao, admin = session?.tipo === "admin";
  $('newVoteBtn').classList.toggle('hidden', !!vote);
  if (!vote) {
    lastEnergyLevel = null;
    lastVoteState = null;
    container.innerHTML = '<div class="empty-state"><div><i data-lucide="vote"></i><p>Nenhuma votação aberta.</p></div></div>';
    return;
  }
  const cast = vote.sim + vote.nao;
  const energyScore = Math.max(0, vote.sim - vote.nao);
  const energyLevel = vote.maioria ? Math.min(100, Math.round(energyScore / vote.maioria * 100)) : 0;
  const energyState = energyLevel === 0 ? "empty" : energyLevel >= 100 ? "full" : energyLevel >= 50 ? "half" : "low";
  const previousLevel = lastEnergyLevel === null ? energyLevel : lastEnergyLevel;
  const sameVote = lastVoteState && lastVoteState.id === vote.id;
  const onlyYesChanged = sameVote && vote.sim > lastVoteState.sim && vote.nao === lastVoteState.nao;
  const onlyNoChanged = sameVote && vote.nao > lastVoteState.nao && vote.sim === lastVoteState.sim;
  const energyDirection = onlyYesChanged ? "filling" : onlyNoChanged ? "draining" : energyLevel > previousLevel ? "filling" : energyLevel < previousLevel ? "draining" : "steady";
  
  container.innerHTML = `<article class="vote-card"><div class="vote-head"><div><p class="eyebrow">Motivo da votação</p><h3>${esc(vote.motivo)}</h3><small>Criada por ${esc(vote.criadoPor || "participante")} · ${cast} de ${vote.total} participantes votaram</small></div><span id="countdown" class="countdown">--:--</span></div><div class="vote-stats"><div class="vote-stat"><strong>${vote.sim}</strong><span>Votos sim</span></div><div class="vote-stat"><strong>${vote.nao}</strong><span>Votos não</span></div><div class="vote-stat"><strong>${vote.faltamParaAprovar}</strong><span>Faltam para aprovar</span></div></div><div class="energy-gauge"><div class="energy-bottle ${energyState}" role="img" aria-label="Nível de energia em ${energyLevel} por cento"><span class="bottle-cap"></span><span class="bottle-neck"></span><span class="bottle-body"><span class="energy-liquid" style="height:${energyLevel}%"><i></i><i></i><i></i></span><span class="bottle-mark"><i data-lucide="zap"></i></span></span></div><div class="energy-gauge-copy"><p class="eyebrow">Energia da votação</p><strong>${energyLevel}%</strong><span>${energyScore} de ${vote.maioria} cargas</span><small>Sim enche, não esvazia</small></div></div><div class="vote-body"><p class="eyebrow">Já votaram</p><div class="voter-chips">${vote.votantes.length ? vote.votantes.map(name => `<span class="voter-chip">${esc(name)}</span>`).join("") : "<span class='optional'>Nenhum voto ainda</span>"}</div>${admin ? '<button id="voteFinishInline" class="button secondary">Finalizar agora</button>' : vote.meuVoto ? `<span class="status-pill green">Seu voto: ${esc(vote.meuVoto.toUpperCase())}</span>` : '<div class="vote-actions"><button id="voteYes" class="button primary">Votar sim</button><button id="voteNo" class="button secondary">Votar não</button></div>'}</div></article>`;
  
  const bottle = container.querySelector('.energy-bottle'), liquid = container.querySelector('.energy-liquid');
  if (bottle && liquid && energyDirection !== "steady") {
    if (energyDirection === "draining") bottle.classList.remove('empty');
    bottle.classList.add(energyDirection);
    liquid.style.height = `${previousLevel}%`;
    void liquid.offsetHeight;
    requestAnimationFrame(() => { liquid.style.height = `${energyLevel}%`; });
    setTimeout(() => { bottle.classList.remove(energyDirection); if (energyLevel === 0) bottle.classList.add('empty'); }, 1300);
  }
  lastEnergyLevel = energyLevel;
  lastVoteState = { id: vote.id, sim: vote.sim, nao: vote.nao };
  
  if (admin) {
    const finishButton = $('voteFinishInline'), actions = document.createElement('div'), cancelButton = document.createElement('button');
    actions.className = 'vote-actions';
    finishButton.onclick = finishVote;
    finishButton.parentNode.insertBefore(actions, finishButton);
    actions.appendChild(finishButton);
    cancelButton.type = 'button';
    cancelButton.className = 'button danger-outline';
    cancelButton.innerHTML = '<i data-lucide="ban"></i>Cancelar votação';
    cancelButton.onclick = cancelVote;
    actions.appendChild(cancelButton);
  } else if (!vote.meuVoto) {
    $('voteYes').onclick = () => castVote('sim');
    $('voteNo').onclick = () => castVote('nao');
  }
  updateCountdown();
  countdownTimer = setInterval(updateCountdown, 1000);
}

function parseBrDate(value) {
  const match = String(value).match(/(\d{2})\/(\d{2})\/(\d{4}) (\d{2}):(\d{2}):(\d{2})/);
  return match ? new Date(+match[3], +match[2] - 1, +match[1], +match[4], +match[5], +match[6]) : null;
}
function updateCountdown() {
  const element = $('countdown'), end = parseBrDate(state.votacao?.encerraEm);
  if (!element || !end) return;
  const seconds = Math.max(0, Math.floor((end - Date.now()) / 1000));
  element.textContent = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  if (!seconds) loadState(true);
}

function castVote(value) { confirmAction(`Votar ${value}`, "O voto não poderá ser alterado depois da confirmação.", button => execute("castVote", { voto: value }, "Voto registrado.", button)); }
function finishVote() { confirmAction("Finalizar votação", "O resultado será calculado com os votos recebidos até agora.", button => execute("finishVote", {}, "Votação finalizada.", button)); }
function cancelVote() { confirmAction("Cancelar votação", "A votação será encerrada sem resultado.", button => execute("cancelVote", {}, "Votação cancelada.", button), true); }

function parseDateKey(value) { const match = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})$/); return match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])) : null; }
function purchaseRecords() { return state.meta.compras?.registros || []; }
function filteredPurchaseRecords() {
  const records = purchaseRecords();
  if (purchasePeriod === "all") return records;
  const today = new Date(), start = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  if (purchasePeriod === "7" || purchasePeriod === "30" || purchasePeriod === "90") start.setDate(start.getDate() - Number(purchasePeriod) + 1);
  return records.filter(record => {
    const date = parseDateKey(record.data);
    if (!date) return false;
    if (purchasePeriod === "month") return date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth();
    if (purchasePeriod === "year") return date.getFullYear() === today.getFullYear();
    return date >= start && date <= today;
  });
}

function renderPurchaseStats() {
  const container = $('purchaseStats'); if (!container) return;
  const stats = state.meta.compras || { precoUnitario: 17.5, litrosPorUnidade: 2, registros: [] };
  const records = filteredPurchaseRecords(), counts = {}; let quantity = 0;
  records.forEach(record => { const amount = Number(record.quantidade) || 0; quantity += amount; counts[record.nome] = (counts[record.nome] || 0) + amount; });
  const people = Object.keys(counts).map(nome => ({ nome, quantidade: counts[nome] })).sort((a, b) => b.quantidade - a.quantidade || a.nome.localeCompare(b.nome));
  const max = Math.max(1, ...people.map(item => item.quantidade));
  const unitPrice = Number(stats.precoUnitario) || 17.5, unitLiters = Number(stats.litrosPorUnidade) || 2;
  const money = value => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(Number(value) || 0);
  const number = value => new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 2 }).format(Number(value) || 0);
  
  container.innerHTML = `<div class="purchase-metrics"><div class="purchase-metric"><span class="metric-icon"><i data-lucide="package-check"></i></span><div><small>Energéticos comprados</small><strong>${quantity}</strong></div></div><div class="purchase-metric"><span class="metric-icon money"><i data-lucide="wallet-cards"></i></span><div><small>Valor total</small><strong>${money(quantity * unitPrice)}</strong><span>${money(unitPrice)} por unidade</span></div></div><div class="purchase-metric"><span class="metric-icon volume"><i data-lucide="droplets"></i></span><div><small>Volume total</small><strong>${number(quantity * unitLiters)} L</strong><span>${number(unitLiters)} L por unidade</span></div></div></div><div class="purchase-chart"><div class="chart-heading"><div><p class="eyebrow">Compras por participante</p><h3>Distribuição</h3></div><select id="purchasePeriodFilter" class="period-filter" aria-label="Período do gráfico"><option value="all">Todo o período</option><option value="7">Últimos 7 dias</option><option value="30">Últimos 30 dias</option><option value="90">Últimos 90 dias</option><option value="month">Este mês</option><option value="year">Este ano</option></select></div><div class="chart-total">${quantity} unidades no período</div><div class="chart-bars">${people.length ? people.map(item => `<div class="chart-row"><span title="${esc(item.nome)}">${esc(item.nome)}</span><div class="chart-track"><i style="width:${Math.max(6, Math.round(item.quantidade / max * 100))}%"></i></div><strong>${item.quantidade}</strong></div>`).join("") : '<div class="chart-empty">Nenhuma compra neste período.</div>'}</div></div>`;
  
  const filter = $('purchasePeriodFilter'); filter.value = purchasePeriod;
  filter.onchange = () => { purchasePeriod = filter.value; renderPurchaseStats(); };
  icons();
}

function renderPurchaseCalendar() {
  const container = $('purchaseCalendar'); if (!container) return;
  const today = new Date();
  const year = purchaseCalendarDate.getFullYear();
  const month = purchaseCalendarDate.getMonth();
  const firstDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();

  const records = purchaseRecords();
  let totalUnitsMonth = 0;
  const daily = {};
  records.forEach(record => {
    if (!record.data) return;
    const d = new Date(record.data + "T00:00:00");
    if (d.getFullYear() === year && d.getMonth() === month) {
      const qtd = Number(record.quantidade) || 1;
      totalUnitsMonth += qtd;
      daily[record.data] = (daily[record.data] || 0) + qtd;
    }
  });
  const totalLitersMonth = totalUnitsMonth * 2;

  const monthName = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric" }).format(purchaseCalendarDate);
  const formattedMonthName = monthName.charAt(0).toUpperCase() + monthName.slice(1);

  let gridHtml = "";
  for (let blank = 0; blank < firstDay; blank += 1) {
    gridHtml += '<div class="calendar-day outside" aria-hidden="true"></div>';
  }

  for (let day = 1; day <= daysInMonth; day += 1) {
    const dateStr = `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
    const amount = daily[dateStr] || 0;
    const isToday = (today.getFullYear() === year && today.getMonth() === month && today.getDate() === day);

    const classes = ["calendar-day"];
    if (amount > 0) classes.push("has-purchase");
    if (isToday) classes.push("today");

    let bottleHtml = "";
    if (amount > 0) {
      bottleHtml = '<div class="calendar-bottle"><i></i><b><em></em></b></div>';
    }
    let countHtml = "";
    if (amount > 0) {
      countHtml = `<span class="calendar-count">${amount}</span>`;
    }

    gridHtml += `<div class="${classes.join(" ")}"><span class="calendar-number">${day}</span>${bottleHtml}${countHtml}</div>`;
  }

  container.innerHTML = `
    <div class="calendar-head">
      <div>
        <p class="eyebrow">CALENDARIO DE COMPRAS</p>
        <h3>${formattedMonthName}</h3>
      </div>
      <div class="calendar-summary">
        <span>${totalUnitsMonth} unidades</span>
        <span>${totalLitersMonth} L</span>
      </div>
      <div class="calendar-nav">
        <button id="prevMonthBtn" class="icon-button" title="Mês anterior"><i data-lucide="chevron-left"></i></button>
        <button id="todayMonthBtn" class="button secondary">Hoje</button>
        <button id="nextMonthBtn" class="icon-button" title="Próximo mês"><i data-lucide="chevron-right"></i></button>
      </div>
    </div>
    <div class="calendar-weekdays">
      <span>DOM</span>
      <span>SEG</span>
      <span>TER</span>
      <span>QUA</span>
      <span>QUI</span>
      <span>SEX</span>
      <span>SÁB</span>
    </div>
    <div class="calendar-grid">
      ${gridHtml}
    </div>
  `;

  $('prevMonthBtn').onclick = () => { purchaseCalendarDate.setMonth(purchaseCalendarDate.getMonth() - 1); renderPurchaseCalendar(); };
  $('nextMonthBtn').onclick = () => { purchaseCalendarDate.setMonth(purchaseCalendarDate.getMonth() + 1); renderPurchaseCalendar(); };
  $('todayMonthBtn').onclick = () => { purchaseCalendarDate = new Date(today.getFullYear(), today.getMonth(), 1); renderPurchaseCalendar(); };
  icons();
}


function renderHistory() {
  const term = $('historySearch').value.trim().toLowerCase(), type = $('historyFilter').value;
  const rows = [...state.historico].filter(item => (!type || item.tipo === type) && (!term || `${item.texto} ${item.pagador} ${item.ator}`.toLowerCase().includes(term)));
  $('historyList').innerHTML = rows.length ? rows.map(item => `<article class="timeline-item"><span class="timeline-dot ${esc(item.tipo)}"></span><div class="timeline-content"><p>${esc(item.texto)}</p>${item.ator ? `<small>Por ${esc(item.ator)}</small>` : ""}</div><time class="timeline-date">${esc(item.data)}</time></article>`).join("") : '<div class="empty-state"><div><i data-lucide="search-x"></i><p>Nenhum registro encontrado.</p></div></div>';
  icons();
}

function renderAdmin() {
  const select = $('nextSelect');
  select.innerHTML = state.pessoas.filter(person => !person.pausado).map(person => `<option value="${esc(person.nome)}">${esc(person.nome)}</option>`).join("");
  $('finishVoteBtn').disabled = !state.votacao;
  $('cancelVoteBtn').disabled = !state.votacao;
}

async function execute(action, payload, message, button) {
  if (actionInFlight) return;
  actionInFlight = true;
  setActionLoading(button, true);
  try {
    const data = await api(action, payload);
    closeModal();
    closeDrawer();
    applyState(data);
    toast(message);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    actionInFlight = false;
    setActionLoading(button, false);
  }
}

function openModal(eyebrow, title, body, actions) {
  $('modalEyebrow').textContent = eyebrow;
  $('modalTitle').textContent = title;
  $('modalBody').innerHTML = body;
  $('modalActions').innerHTML = actions;
  $('modal').showModal();
  icons();
}
function closeModal() { if ($('modal').open) $('modal').close(); }

function confirmAction(title, text, onConfirm, danger = false) {
  openModal("Confirmação", title, `<p class="confirm-copy">${esc(text)}</p>`, `<button type="button" class="button secondary" data-modal-close>Cancelar</button><button id="confirmModalBtn" type="button" class="button ${danger ? "danger-outline" : "dark"}">Confirmar</button>`);
  const confirmButton = $('confirmModalBtn');
  confirmButton.onclick = () => onConfirm(confirmButton);
  bindModalClose();
}
function bindModalClose() { document.querySelectorAll('[data-modal-close]').forEach(button => button.onclick = closeModal); }

function showAccessCode(name, code) {
  openModal("Primeiro acesso", `Código de ${name}`, `<div class="code-box"><span>Código temporário</span><strong>${esc(code)}</strong></div><p class="confirm-copy">Informe este código ao participante. Ele será usado apenas ao cadastrar a nova senha.</p>`, `<button type="button" class="button dark" data-modal-close>Concluir</button>`);
  bindModalClose();
}

function openAddPerson() {
  openModal("Participantes", "Adicionar à fila", '<div class="field"><label for="newPersonName">Nome</label><input id="newPersonName" autocomplete="off" placeholder="Nome do participante"></div>', '<button type="button" class="button secondary" data-modal-close>Cancelar</button><button id="savePersonBtn" type="button" class="button dark">Adicionar</button>');
  const button = $('savePersonBtn');
  button.onclick = () => {
    const nome = $('newPersonName').value.trim();
    if (nome) execute("addPerson", { nome }, "Participante adicionado.", button);
  };
  bindModalClose();
  $('newPersonName').focus();
}

function openVoteModal() {
  openModal("Votação", "Nova compra extra", '<div class="field"><label for="voteReason">Motivo</label><input id="voteReason" maxlength="100" placeholder="Ex.: reposição para a reunião"></div>', '<button type="button" class="button secondary" data-modal-close>Cancelar</button><button id="saveVoteBtn" type="button" class="button dark">Abrir votação</button>');
  const button = $('saveVoteBtn');
  button.onclick = () => execute("createVote", { motivo: $('voteReason').value.trim() || "Compra extra" }, "Votação aberta.", button);
  bindModalClose();
  $('voteReason').focus();
}

function openPaymentModal() {
  const pending = state.pagamentoPendente;
  openModal("Pagamento", pending ? pending.tipo : "Registrar compra", `<div class="field-row"><div class="field"><label for="paymentValue">Valor</label><input id="paymentValue" inputmode="decimal" placeholder="17,50"></div><div class="field"><label for="paymentMethod">Forma</label><select id="paymentMethod"><option value="PIX">PIX</option><option value="Dinheiro">Dinheiro</option><option value="Cartão">Cartão</option></select></div></div><div class="field"><label for="paymentProof">Comprovante <span class="optional">link ou referência</span></label><input id="paymentProof" placeholder="Opcional"></div>`, `<button type="button" class="button secondary" data-modal-close>Cancelar</button><button id="savePaymentBtn" type="button" class="button dark">Confirmar e avançar</button>`);
  const button = $('savePaymentBtn');
  button.onclick = () => execute("registerPurchase", { tipo: pending?.tipo || "Compra registrada pelo admin", valor: $('paymentValue').value.trim(), metodo: $('paymentMethod').value, comprovante: $('paymentProof').value.trim() }, "Compra registrada.", button);
  bindModalClose();
}

function openDrawer() { $('overlay').classList.remove('hidden'); $('adminDrawer').classList.remove('hidden'); icons(); }
function closeDrawer() { $('overlay').classList.add('hidden'); $('adminDrawer').classList.add('hidden'); }

document.querySelectorAll('[data-close]').forEach(button => button.onclick = closeDrawer);
$('overlay').onclick = closeDrawer;
$('refreshBtn').onclick = () => loadState();
$('adminBtn').onclick = openDrawer;
$('logoutBtn').onclick = () => logout();
$('addPersonBtn').onclick = openAddPerson;
$('newVoteBtn').onclick = openVoteModal;
$('registerPurchaseBtn').onclick = openPaymentModal;
$('finishVoteBtn').onclick = finishVote;
$('undoBtn').onclick = () => confirmAction("Desfazer última compra", "O último pagador retornará ao início da fila.", button => execute("undoLastPurchase", {}, "Movimentação desfeita.", button));
$('setNextBtn').onclick = event => execute("setNextPerson", { nome: $('nextSelect').value }, "Próximo pagador atualizado.", event.currentTarget);
$('clearBtn').onclick = () => {
  openModal("Zona de risco", "Apagar todos os dados", '<p class="danger-copy">Digite APAGAR para confirmar a exclusão de todos os dados do banco.</p><div class="field"><input id="clearConfirm" autocomplete="off" placeholder="APAGAR"></div>', '<button type="button" class="button secondary" data-modal-close>Cancelar</button><button id="clearConfirmBtn" type="button" class="button danger-outline">Apagar dados</button>');
  const button = $('clearConfirmBtn');
  button.onclick = () => {
    $('clearConfirm').value === "APAGAR" ? execute("clearAll", {}, "Todos os dados foram apagados.", button) : toast("Digite APAGAR para confirmar.", "error");
  };
  bindModalClose();
};

$('cancelVoteBtn').onclick = cancelVote;
document.querySelectorAll('.tab').forEach(button => button.onclick = () => {
  activeTab = button.dataset.tab;
  document.querySelectorAll('.tab').forEach(item => item.classList.toggle('active', item === button));
  document.querySelectorAll('.tab-view').forEach(view => view.classList.toggle('hidden', view.id !== `view-${activeTab}`));
  if (activeTab === "historico") renderHistory();
});
$('historySearch').oninput = renderHistory;
$('historyFilter').onchange = renderHistory;
document.querySelector('[data-modal-close]').onclick = closeModal;

applyTheme();
$('themeBtn').onclick = toggleTheme;
icons();
showApp();
if (session) loadState(true);
