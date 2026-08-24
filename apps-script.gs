const ADMIN_PASSWORD_PROPERTY = "ADMIN_PASSWORD";
const VOTE_DURATION_MINUTES = 10;
const SESSION_DURATION_HOURS = 12;
const ENERGY_UNIT_PRICE = 17.50;
const ENERGY_UNIT_LITERS = 2;

const SHEETS = {
  pessoas: "pessoas",
  historico: "historico",
  votos: "votos",
  votacoes: "votacoes",
  pendencias: "pendencias",
  requisicoes: "requisicoes",
  movimentacoes: "movimentacoes"
};

const HEADERS = {
  pessoas: ["id", "nome", "ordem", "ativo", "criadoEm", "senhaHash", "pausado", "codigoAtivacaoHash", "senhaSalt"],
  historico: ["data", "tipo", "texto", "pagador", "ator", "detalhes"],
  votos: ["votacaoId", "pessoa", "voto", "data"],
  votacoes: ["id", "status", "criadoEm", "encerradoEm", "resultado", "motivo", "elegiveis", "criadoPor"],
  pendencias: ["id", "tipo", "status", "origem", "dataChave", "criadoEm", "confirmadoEm", "observacao", "valor", "metodo", "comprovante", "confirmadoPor"],
  requisicoes: ["requestId", "action", "data", "ator"],
  movimentacoes: ["id", "tipo", "pessoa", "data", "desfeito", "detalhes"]
};

function setup() {
  setupSheets();
  ensureAutomationTrigger();

  return jsonResponse({
    ok: true,
    message: "Planilha configurada com sucesso."
  });
}

function configureAdminPassword(newPassword) {
  const cleanPassword = String(newPassword || "").trim();

  if (cleanPassword.length < 8) {
    throw new Error("Use uma senha de admin com pelo menos 8 caracteres.");
  }

  PropertiesService.getScriptProperties().setProperty(ADMIN_PASSWORD_PROPERTY, cleanPassword);
  return "Senha de admin atualizada.";
}

function ensureAutomationTrigger() {
  const exists = ScriptApp.getProjectTriggers().some(trigger => trigger.getHandlerFunction() === "scheduledMaintenance");

  if (!exists) {
    ScriptApp.newTrigger("scheduledMaintenance").timeBased().everyMinutes(15).create();
  }
}

function scheduledMaintenance() {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);

  try {
    setupSheets();
    cleanupExpiredSessions();
    closeExpiredVotes();
    syncFridayPaymentPending();
  } finally {
    lock.releaseLock();
  }
}

function setupSheets() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();

  ensureSheet(ss, SHEETS.pessoas, HEADERS.pessoas);
  ensureSheet(ss, SHEETS.historico, HEADERS.historico);
  ensureSheet(ss, SHEETS.votos, HEADERS.votos);
  ensureSheet(ss, SHEETS.votacoes, HEADERS.votacoes);
  ensureSheet(ss, SHEETS.pendencias, HEADERS.pendencias);
  ensureSheet(ss, SHEETS.requisicoes, HEADERS.requisicoes);
  ensureSheet(ss, SHEETS.movimentacoes, HEADERS.movimentacoes);
}

function doGet(e) {
  const callback = getParam(e, "callback");
  const bridge = getParam(e, "bridge");
  const transport = getParam(e, "transport");
  const requestId = getParam(e, "requestId");

  try {
    const action = getParam(e, "action");

    if (!action) {
      setupSheets();

      return jsonResponse({
        ok: true,
        data: { status: "online" }
      });
    }

    if (isMutationAction(action)) {
      throw new Error("Acoes que alteram dados aceitam apenas POST.");
    }

    const lock = LockService.getScriptLock();
    lock.waitLock(10000);

    try {
      setupSheets();

      const payload = {
        ok: true,
        data: runAction(action, e.parameter || {})
      };

      if (transport === "script") {
        return scriptResponse(requestId, payload);
      }

      if (bridge) {
        return bridgeResponse(requestId, payload);
      }

      return apiResponse(callback, payload);
    } finally {
      lock.releaseLock();
    }
  } catch (error) {
    const payload = {
      ok: false,
      error: error.message || String(error)
    };

    if (transport === "script") {
      return scriptResponse(requestId, payload);
    }

    if (bridge) {
      return bridgeResponse(requestId, payload);
    }

    return apiResponse(callback, payload);
  }
}

function doPost(e) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);

  try {
    setupSheets();

    const body = parseBody(e);
    return jsonResponse({
      ok: true,
      data: runAction(body.action, body)
    });
  } catch (error) {
    return errorResponse(error);
  } finally {
    lock.releaseLock();
  }
}

function runAction(action, params) {
  params = params || {};

  if (isMutationAction(action)) {
    const requestId = String(params.requestId || "").trim();

    if (!requestId) {
      throw new Error("Identificador da operacao ausente. Atualize a pagina e tente novamente.");
    }

    if (isIdempotentMutationAction(action) && isProcessedRequest(requestId)) {
      return getAuthorizedState(params);
    }

    const result = dispatchAction(action, params);
    if (isIdempotentMutationAction(action)) {
      recordProcessedRequest(requestId, action, getActorLabel(params));
    }
    return result;
  }

  return dispatchAction(action, params);
}

function dispatchAction(action, params) {
  if (action === "state" || action === "getState") {
    return getAuthorizedState(params);
  }

  if (action === "loginParticipant") {
    return loginParticipant(params.nome, params.senha, params.codigo);
  }

  if (action === "loginAdmin") {
    requireAdmin(params.adminSenha);
    const adminSession = createSession("admin", "Admin");
    return {
      session: adminSession,
      state: getState({ actor: { tipo: "admin", nome: "Admin" } })
    };
  }

  if (action === "addPerson") {
    requireAdmin(params);
    return addPerson(params.nome);
  }

  if (action === "removePerson") {
    requireAdmin(params);
    return removePerson(params.nome);
  }

  if (action === "setNextPerson") {
    requireAdmin(params);
    return setNextPerson(params.nome);
  }

  if (action === "registerPurchase") {
    const admin = requireAdmin(params);
    return registerPurchase(params, admin.nome);
  }

  if (action === "createVote") {
    return createVote(params);
  }

  if (action === "castVote") {
    return castVote(params);
  }

  if (action === "finishVote") {
    requireAdmin(params);
    return finishVote();
  }

  if (action === "cancelVote") {
    const admin = requireAdmin(params);
    return cancelVote(admin.nome);
  }

  if (action === "togglePause") {
    requireAdmin(params);
    return togglePause(params.nome);
  }

  if (action === "undoLastPurchase") {
    const admin = requireAdmin(params);
    return undoLastPurchase(admin.nome);
  }

  if (action === "resetAccess") {
    requireAdmin(params);
    return resetAccess(params.nome);
  }

  if (action === "createBackup") {
    requireAdmin(params);
    return createBackup();
  }

  if (action === "clearAll") {
    requireAdmin(params);
    return clearAll();
  }

  throw new Error("Acao invalida.");
}

function isMutationAction(action) {
  return [
    "loginParticipant", "loginAdmin", "addPerson", "removePerson", "setNextPerson",
    "registerPurchase", "createVote", "castVote", "finishVote", "cancelVote", "togglePause",
    "undoLastPurchase", "resetAccess", "createBackup", "clearAll"
  ].indexOf(action) !== -1;
}

function isIdempotentMutationAction(action) {
  return action !== "loginParticipant" && action !== "loginAdmin" && isMutationAction(action);
}

function isProcessedRequest(requestId) {
  return readRows(SHEETS.requisicoes).some(row => String(row.requestId) === requestId);
}

function recordProcessedRequest(requestId, action, actor) {
  getSheet(SHEETS.requisicoes).appendRow([requestId, action, new Date(), actor || ""]);
}

function loginParticipant(nome, senha, codigo) {
  const person = getPersonByName(nome);

  if (!person) {
    throw new Error("Participante nao encontrado. Peca para o admin cadastrar seu nome.");
  }

  if (!person.ativo) {
    throw new Error("Participante removido da lista.");
  }

  const cleanPassword = String(senha || "").trim();

  if (!cleanPassword) {
    throw new Error("Digite sua senha.");
  }

  if (!person.senhaHash) {
    if (person.codigoAtivacaoHash && person.codigoAtivacaoHash !== hashPassword(String(codigo || "").trim())) {
      throw new Error("Codigo de primeiro acesso incorreto.");
    }

    const salt = Utilities.getUuid();
    getSheet(SHEETS.pessoas).getRange(person.row, 6).setValue(hashPassword(`${salt}:${cleanPassword}`));
    getSheet(SHEETS.pessoas).getRange(person.row, 8).setValue("");
    getSheet(SHEETS.pessoas).getRange(person.row, 9).setValue(salt);
    addHistory("senha", `${person.nome} cadastrou a senha de acesso.`, person.nome);
  } else {
    const validHash = person.senhaSalt
      ? hashPassword(`${person.senhaSalt}:${cleanPassword}`)
      : hashPassword(cleanPassword);

    if (person.senhaHash !== validHash) {
      throw new Error("Senha incorreta.");
    }

    if (!person.senhaSalt) {
      const upgradedSalt = Utilities.getUuid();
      getSheet(SHEETS.pessoas).getRange(person.row, 6).setValue(hashPassword(`${upgradedSalt}:${cleanPassword}`));
      getSheet(SHEETS.pessoas).getRange(person.row, 9).setValue(upgradedSalt);
    }
  }

  const participantSession = createSession("participante", person.nome);

  return {
    session: participantSession,
    state: getState({ actor: { tipo: "participante", nome: person.nome } })
  };
}

function addPerson(nome) {
  const cleanName = String(nome || "").trim();

  if (!cleanName) {
    throw new Error("Digite o nome da pessoa.");
  }

  const people = getPeople();
  const existing = people.find(person => person.nome.toLowerCase() === cleanName.toLowerCase());

  if (existing && existing.ativo) {
    throw new Error("Essa pessoa ja esta na fila.");
  }

  if (existing && !existing.ativo) {
    const activePeople = people.filter(person => person.ativo);
    const nextOrder = activePeople.length ? Math.max(...activePeople.map(person => person.ordem)) + 1 : 1;
    const sheet = getSheet(SHEETS.pessoas);

    sheet.getRange(existing.row, 3).setValue(nextOrder);
    sheet.getRange(existing.row, 4).setValue(true);
    sheet.getRange(existing.row, 6).setValue("");
    sheet.getRange(existing.row, 7).setValue(false);
    const activationCode = generateActivationCode();
    sheet.getRange(existing.row, 8).setValue(hashPassword(activationCode));
    sheet.getRange(existing.row, 9).setValue("");

    addHistory(
      "entrada",
      `${existing.nome} voltou para a lista, pagou o energetico de entrada e foi colocado no final da fila.`,
      existing.nome
    );

    const reactivatedState = getState({ actor: { tipo: "admin", nome: "Admin" } });
    reactivatedState.meta.codigoAtivacao = activationCode;
    reactivatedState.meta.codigoNome = existing.nome;
    return reactivatedState;
  }

  const activePeople = people.filter(person => person.ativo);
  const sheet = getSheet(SHEETS.pessoas);
  const nextOrder = activePeople.length ? Math.max(...activePeople.map(person => person.ordem)) + 1 : 1;
  const activationCode = generateActivationCode();

  sheet.appendRow([
    Utilities.getUuid(),
    cleanName,
    nextOrder,
    true,
    new Date(),
    "",
    false,
    hashPassword(activationCode),
    ""
  ]);

  addHistory(
    "entrada",
    `${cleanName} entrou na lista, pagou o energetico de entrada e foi colocado no final da fila.`,
    cleanName
  );

  const state = getState({ actor: { tipo: "admin", nome: "Admin" } });
  state.meta.codigoAtivacao = activationCode;
  state.meta.codigoNome = cleanName;
  return state;
}

function removePerson(nome) {
  const person = getPersonByName(nome);

  if (!person || !person.ativo) {
    throw new Error("Participante nao encontrado.");
  }

  getSheet(SHEETS.pessoas).getRange(person.row, 4).setValue(false);
  addHistory("remocao", `${person.nome} foi removido da lista pelo admin.`, person.nome);

  return getState({ admin: "true" });
}

function setNextPerson(nome) {
  const selected = getPersonByName(nome);

  if (!selected || !selected.ativo) {
    throw new Error("Participante nao encontrado.");
  }

  if (selected.pausado) {
    throw new Error("Retome o participante antes de coloca-lo no inicio da fila.");
  }

  const people = getActivePeople();
  const reordered = [
    selected,
    ...people.filter(person => person.nome.toLowerCase() !== selected.nome.toLowerCase())
  ];

  reordered.forEach((person, index) => {
    updatePersonOrder(person.row, index + 1);
  });

  addHistory("fila", `${selected.nome} foi selecionado pelo admin como proximo da fila.`, selected.nome);

  return getState({ admin: "true" });
}

function registerPurchase(params, actorName) {
  const fridayPendingWasSettled = syncFridayPaymentPending();

  if (fridayPendingWasSettled) {
    return getState({ admin: "true" });
  }

  const pending = getOpenPaymentPending();
  const purchaseType = pending ? pending.tipo : params.tipo;
  const paymentDetails = {
    valor: String(params.valor || "").trim(),
    metodo: String(params.metodo || "").trim(),
    comprovante: String(params.comprovante || "").trim(),
    ator: actorName || "Admin"
  };

  advanceQueue(purchaseType, paymentDetails);

  if (pending) {
    confirmPaymentPending(pending, false, paymentDetails);
  }

  return getState({ admin: "true" });
}

function advanceQueue(tipo, details) {
  const people = getActivePeople();

  if (!people.length) {
    throw new Error("Adicione pessoas na fila primeiro.");
  }

  const purchaseType = String(tipo || "Compra").trim();
  const payer = people[0];
  const lastOrder = Math.max(...people.map(person => person.ordem));

  getSheet(SHEETS.movimentacoes).appendRow([
    Utilities.getUuid(),
    "compra",
    payer.nome,
    new Date(),
    false,
    JSON.stringify({ tipo: purchaseType, ordemAnterior: payer.ordem })
  ]);

  updatePersonOrder(payer.row, lastOrder + 1);

  const detailText = [
    details && details.valor ? `Valor: R$ ${details.valor}` : "",
    details && details.metodo ? `Metodo: ${details.metodo}` : "",
    details && details.comprovante ? `Comprovante: ${details.comprovante}` : ""
  ].filter(Boolean).join(". ");

  addHistory(
    "compra",
    `${payer.nome} pagou o energetico. Tipo da compra: ${purchaseType}. A fila avancou.${detailText ? ` ${detailText}.` : ""}`,
    payer.nome,
    details && details.ator ? details.ator : "Admin",
    details || {}
  );
}

function createVote(params) {
  const actor = requireLoggedUser(params);
  closeExpiredVotes();

  if (getActiveVote()) {
    throw new Error("Ja existe uma votacao aberta.");
  }

  if (!getActivePeople().length) {
    throw new Error("Adicione pessoas na fila primeiro.");
  }

  const eligibleNames = getActivePeople().map(person => person.nome);
  const reason = String(params.motivo || "Compra extra").trim();

  getSheet(SHEETS.votacoes).appendRow([
    Utilities.getUuid(),
    "aberta",
    new Date(),
    "",
    "",
    reason,
    JSON.stringify(eligibleNames),
    actor.nome
  ]);

  addHistory("votacao", `${actor.nome} abriu uma votacao: ${reason}. A votacao dura no maximo ${VOTE_DURATION_MINUTES} minutos.`, actor.nome, actor.nome, { motivo: reason });

  return getState({ actor });
}

function castVote(params) {
  closeExpiredVotes();
  const activeVote = getActiveVote();

  if (!activeVote) {
    throw new Error("Nao existe votacao aberta.");
  }

  const actor = requireLoggedUser(params);

  if (actor.tipo !== "participante") {
    throw new Error("Somente participantes podem votar.");
  }

  const person = getPersonByName(actor.nome);
  const eligible = activeVote.elegiveis || [];

  if (eligible.length && eligible.map(name => name.toLowerCase()).indexOf(person.nome.toLowerCase()) === -1) {
    throw new Error("Voce nao estava elegivel quando esta votacao comecou.");
  }

  const cleanVote = String(params.voto || "").trim().toLowerCase();

  if (cleanVote !== "sim" && cleanVote !== "nao") {
    throw new Error("Escolha apenas sim ou nao.");
  }

  const votes = getVotesFor(activeVote.id);
  const existing = votes.find(item => item.pessoa.toLowerCase() === person.nome.toLowerCase());

  if (existing) {
    throw new Error("Voce ja votou nesta votacao.");
  }

  getSheet(SHEETS.votos).appendRow([
    activeVote.id,
    person.nome,
    cleanVote,
    new Date()
  ]);

  const updatedVotes = getVotesFor(activeVote.id);
  const simCount = updatedVotes.filter(item => item.voto === "sim").length;
  if (simCount >= 4) {
    finalizeVote(activeVote, "auto_4_sim");
  }

  return getState({ actor });
}

function finishVote() {
  const hadOpenVote = !!getActiveVote();
  closeExpiredVotes();
  const activeVote = getActiveVote();

  if (!activeVote) {
    if (hadOpenVote) {
      return getState({ admin: "true" });
    }

    throw new Error("Nao existe votacao aberta.");
  }

  finalizeVote(activeVote, "manual");
  return getState({ admin: "true" });
}

function cancelVote(actorName) {
  closeExpiredVotes();
  const activeVote = getActiveVote();

  if (!activeVote) {
    throw new Error("Nao existe votacao aberta para cancelar.");
  }

  const sheet = getSheet(SHEETS.votacoes);
  sheet.getRange(activeVote.row, 2).setValue("cancelada");
  sheet.getRange(activeVote.row, 4).setValue(new Date());
  sheet.getRange(activeVote.row, 5).setValue("cancelada");

  addHistory(
    "votacao",
    `Votacao cancelada pelo admin. Motivo: ${activeVote.motivo || "Compra extra"}.`,
    "",
    actorName || "Admin",
    { votacaoId: activeVote.id, resultado: "cancelada" }
  );

  return getState({ actor: { tipo: "admin", nome: actorName || "Admin" } });
}

function finalizeVote(activeVote, reason) {
  const votes = getVotesFor(activeVote.id);
  const sim = votes.filter(item => item.voto === "sim").length;
  const nao = votes.filter(item => item.voto === "nao").length;
  const eligibleCount = activeVote.elegiveis && activeVote.elegiveis.length
    ? activeVote.elegiveis.length
    : getActivePeople().length;
  const majority = 4;
  const approved = sim >= 4 || sim >= majority;
  const result = approved ? "aprovada" : "recusada";

  const sheet = getSheet(SHEETS.votacoes);
  sheet.getRange(activeVote.row, 2).setValue("encerrada");
  sheet.getRange(activeVote.row, 4).setValue(new Date());
  sheet.getRange(activeVote.row, 5).setValue(result);

  if (approved) {
    createPaymentPending(
      "Compra extra aprovada por votacao",
      "votacao",
      activeVote.id,
      `Votos SIM: ${sim}, votos NAO: ${nao}.`
    );

    addHistory(
      "votacao",
      `Compra extra aprovada por votacao ${reason === "automatico" ? "encerrada automaticamente" : "encerrada pelo admin"}. Votos SIM: ${sim}, votos NAO: ${nao}. O admin ainda precisa registrar a compra para a fila avancar.`,
      ""
    );
  } else {
    addHistory(
      "votacao",
      `Compra extra recusada em votacao ${reason === "automatico" ? "encerrada automaticamente" : "encerrada pelo admin"}. Votos SIM: ${sim}, votos NAO: ${nao}. Era necessario pelo menos ${majority} voto(s) SIM.`,
      ""
    );
  }
}

function createPaymentPending(tipo, origem, dataChave, observacao) {
  const existing = getOpenPaymentPending();

  if (existing) {
    return existing;
  }

  const pending = {
    id: Utilities.getUuid(),
    tipo,
    status: "pendente",
    origem,
    dataChave: dataChave || "",
    criadoEm: new Date(),
    confirmadoEm: "",
    observacao: observacao || ""
  };

  getSheet(SHEETS.pendencias).appendRow([
    pending.id,
    pending.tipo,
    pending.status,
    pending.origem,
    pending.dataChave,
    pending.criadoEm,
    pending.confirmadoEm,
    pending.observacao,
    "",
    "",
    "",
    ""
  ]);

  addHistory(
    "pagamento",
    `Pagamento pendente: ${pending.tipo}. O admin precisa confirmar para a fila avancar.`,
    ""
  );

  return pending;
}

function confirmPaymentPending(pending, automatic, details) {
  const row = pending.row;
  const sheet = getSheet(SHEETS.pendencias);

  sheet.getRange(row, 3).setValue("confirmado");
  sheet.getRange(row, 7).setValue(new Date());
  sheet.getRange(row, 9).setValue(details && details.valor ? details.valor : "");
  sheet.getRange(row, 10).setValue(details && details.metodo ? details.metodo : "");
  sheet.getRange(row, 11).setValue(details && details.comprovante ? details.comprovante : "");
  sheet.getRange(row, 12).setValue(details && details.ator ? details.ator : (automatic ? "Sistema" : "Admin"));

  const actor = automatic ? "automaticamente pelo historico" : "pelo admin";
  addHistory("pagamento", `Pagamento confirmado ${actor}: ${pending.tipo}.`, "", details && details.ator ? details.ator : "Sistema", details || {});
}

function syncFridayPaymentPending() {
  const todayKey = getTodayKey();
  const openPending = getOpenPaymentPending();

  if (openPending && isFridayPaymentPending(openPending)) {
    const pendingDateKey = normalizeDateKey(openPending.dataChave) || normalizeDateKey(openPending.criadoEm);

    if (hasPurchaseInHistory(pendingDateKey)) {
      confirmPaymentPending(openPending, true);
      return true;
    }
  }

  if (!isFridayToday()) return false;
  if (openPending) return false;
  if (hasConfirmedFridayPayment(todayKey)) return false;
  if (hasPurchaseInHistory(todayKey)) return false;

  createPaymentPending(
    "Sexta-feira obrigatoria",
    "sexta",
    todayKey,
    "Pagamento obrigatorio de sexta-feira."
  );

  return false;
}

function getOpenPaymentPending() {
  return getPaymentPendings()
    .filter(item => item.status === "pendente")
    .sort((a, b) => b.row - a.row)[0] || null;
}

function getPaymentPendings() {
  return readRows(SHEETS.pendencias)
    .map((row, index) => ({
      id: row.id,
      tipo: row.tipo,
      status: String(row.status || "").trim().toLowerCase(),
      origem: row.origem || "",
      dataChave: row.dataChave || "",
      criadoEm: row.criadoEm,
      confirmadoEm: row.confirmadoEm,
      observacao: row.observacao || "",
      valor: row.valor || "",
      metodo: row.metodo || "",
      comprovante: row.comprovante || "",
      confirmadoPor: row.confirmadoPor || "",
      row: index + 2
    }))
    .filter(item => item.id);
}

function hasConfirmedFridayPayment(dateKey) {
  return getPaymentPendings().some(item => (
    String(item.origem || "").toLowerCase() === "sexta" &&
    normalizeDateKey(item.dataChave) === dateKey &&
    item.status === "confirmado"
  ));
}

function isFridayPaymentPending(pending) {
  return String(pending.origem || "").toLowerCase() === "sexta";
}

function hasPurchaseInHistory(dateKey) {
  if (!dateKey) return false;

  return readRows(SHEETS.historico).some(row => {
    const type = String(row.tipo || "").trim().toLowerCase();
    const text = String(row.texto || "").trim().toLowerCase();

    return normalizeDateKey(row.data) === dateKey && (
      type === "compra" ||
      (type === "pagamento" && text.indexOf("pagamento confirmado") !== -1)
    );
  });
}

function isFridayToday() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "u") === "5";
}

function getTodayKey() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "yyyy-MM-dd");
}

function normalizeDateKey(value) {
  if (!value) return "";

  if (Object.prototype.toString.call(value) === "[object Date]") {
    return Utilities.formatDate(value, Session.getScriptTimeZone(), "yyyy-MM-dd");
  }

  const text = String(value).trim();
  const isoMatch = text.match(/^(\d{4})-(\d{2})-(\d{2})/);

  if (isoMatch) {
    return `${isoMatch[1]}-${isoMatch[2]}-${isoMatch[3]}`;
  }

  const brMatch = text.match(/^(\d{2})\/(\d{2})\/(\d{4})/);

  if (brMatch) {
    return `${brMatch[3]}-${brMatch[2]}-${brMatch[1]}`;
  }

  return text;
}

function togglePause(nome) {
  const person = getPersonByName(nome);

  if (!person || !person.ativo) {
    throw new Error("Participante nao encontrado.");
  }

  const nextPaused = !person.pausado;
  getSheet(SHEETS.pessoas).getRange(person.row, 7).setValue(nextPaused);
  addHistory(
    "fila",
    nextPaused ? `${person.nome} foi colocado em pausa.` : `${person.nome} voltou para a fila.`,
    person.nome,
    "Admin",
    { pausado: nextPaused }
  );

  return getState({ actor: { tipo: "admin", nome: "Admin" } });
}

function resetAccess(nome) {
  const person = getPersonByName(nome);

  if (!person || !person.ativo) {
    throw new Error("Participante nao encontrado.");
  }

  const activationCode = generateActivationCode();
  const sheet = getSheet(SHEETS.pessoas);
  sheet.getRange(person.row, 6).setValue("");
  sheet.getRange(person.row, 8).setValue(hashPassword(activationCode));
  sheet.getRange(person.row, 9).setValue("");
  addHistory("acesso", `Um novo codigo de acesso foi gerado para ${person.nome}.`, person.nome, "Admin", {});

  const state = getState({ actor: { tipo: "admin", nome: "Admin" } });
  state.meta.codigoAtivacao = activationCode;
  state.meta.codigoNome = person.nome;
  return state;
}

function generateActivationCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

function undoLastPurchase(actorName) {
  const movements = readRows(SHEETS.movimentacoes)
    .map((row, index) => ({
      id: row.id,
      tipo: row.tipo,
      pessoa: row.pessoa,
      data: row.data,
      desfeito: row.desfeito === true || String(row.desfeito).toLowerCase() === "true",
      row: index + 2
    }))
    .filter(item => item.tipo === "compra" && !item.desfeito)
    .sort((a, b) => b.row - a.row);
  const movement = movements[0];

  if (!movement) {
    throw new Error("Nao existe uma compra recente para desfazer.");
  }

  const person = getPersonByName(movement.pessoa);

  if (!person || !person.ativo) {
    throw new Error("O participante da ultima compra nao esta mais ativo.");
  }

  const people = getPeople().filter(item => item.ativo);
  const reordered = [person].concat(people.filter(item => item.id !== person.id));
  reordered.forEach((item, index) => updatePersonOrder(item.row, index + 1));
  getSheet(SHEETS.movimentacoes).getRange(movement.row, 5).setValue(true);
  addHistory("ajuste", `A ultima movimentacao de ${person.nome} foi desfeita.`, person.nome, actorName || "Admin", { movimentacaoId: movement.id });

  return getState({ actor: { tipo: "admin", nome: actorName || "Admin" } });
}

function createBackup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const timezone = Session.getScriptTimeZone();
  const name = `${ss.getName()} - backup ${Utilities.formatDate(new Date(), timezone, "yyyy-MM-dd HH-mm-ss")}`;
  DriveApp.getFileById(ss.getId()).makeCopy(name);
  addHistory("backup", `Backup criado: ${name}.`, "", "Admin", { nome: name });
  return getState({ actor: { tipo: "admin", nome: "Admin" } });
}

function clearAll() {
  createBackup();
  clearSheet(SHEETS.pessoas, HEADERS.pessoas);
  clearSheet(SHEETS.historico, HEADERS.historico);
  clearSheet(SHEETS.votos, HEADERS.votos);
  clearSheet(SHEETS.votacoes, HEADERS.votacoes);
  clearSheet(SHEETS.pendencias, HEADERS.pendencias);
  clearSheet(SHEETS.requisicoes, HEADERS.requisicoes);
  clearSheet(SHEETS.movimentacoes, HEADERS.movimentacoes);

  return getState({ admin: "true" });
}

function getState(params) {
  closeExpiredVotes();
  syncFridayPaymentPending();

  const activeVote = getActiveVote();
  const listedPeople = getPeople().filter(person => person.ativo);
  const activePeople = getActivePeople();
  const votes = activeVote ? getVotesFor(activeVote.id) : [];
  const pendingPayment = getOpenPaymentPending();
  const actor = params && params.actor ? params.actor : null;
  const me = actor && actor.tipo === "participante" ? getPersonByName(actor.nome) : null;
  let myVote = "";

  if (me) {
    const foundVote = votes.find(item => item.pessoa.toLowerCase() === me.nome.toLowerCase());
    myVote = foundVote ? foundVote.voto : "";
  }

  const eligibleCount = activeVote && activeVote.elegiveis && activeVote.elegiveis.length
    ? activeVote.elegiveis.length
    : activePeople.length;
  const majority = Math.floor(eligibleCount / 2) + 1;
  const canUndo = readRows(SHEETS.movimentacoes).some(row => (
    String(row.tipo || "") === "compra" &&
    !(row.desfeito === true || String(row.desfeito).toLowerCase() === "true")
  ));

  return {
    pessoas: listedPeople.map(person => ({
      nome: person.nome,
      hasPassword: !!person.senhaHash,
      pausado: person.pausado
    })),
    historico: getHistory(),
    meta: {
      atualizadoEm: formatDate(new Date()),
      ativos: activePeople.length,
      pausados: listedPeople.filter(person => person.pausado).length,
      podeDesfazer: canUndo,
      compras: getPurchaseStats()
    },
    pagamentoPendente: pendingPayment ? {
      id: pendingPayment.id,
      tipo: pendingPayment.tipo,
      origem: pendingPayment.origem,
      criadoEm: formatDate(pendingPayment.criadoEm),
      observacao: pendingPayment.observacao || "",
      valor: pendingPayment.valor || "",
      metodo: pendingPayment.metodo || "",
      comprovante: pendingPayment.comprovante || ""
    } : null,
    votacao: activeVote ? {
      id: activeVote.id,
      status: activeVote.status,
      criadoEm: formatDate(activeVote.criadoEm),
      encerraEm: formatDate(getVoteEndDate(activeVote)),
      sim: votes.filter(item => item.voto === "sim").length,
      nao: votes.filter(item => item.voto === "nao").length,
      total: eligibleCount,
      maioria: majority,
      faltamParaAprovar: Math.max(majority - votes.filter(item => item.voto === "sim").length, 0),
      votantes: votes.map(item => item.pessoa),
      meuVoto: myVote,
      motivo: activeVote.motivo || "Compra extra",
      criadoPor: activeVote.criadoPor || ""
    } : null
  };
}

function requireAdmin(credentials) {
  if (typeof credentials === "string") {
    if (String(credentials || "") !== getAdminPassword()) {
      throw new Error("Senha de admin incorreta.");
    }

    return { tipo: "admin", nome: "Admin" };
  }

  const actor = requireSession(credentials);

  if (actor.tipo !== "admin") {
    throw new Error("Senha de admin incorreta.");
  }

  return actor;
}

function requireLoggedUser(params) {
  return requireSession(params);
}

function getAdminPassword() {
  const password = PropertiesService.getScriptProperties().getProperty(ADMIN_PASSWORD_PROPERTY);

  if (!password) {
    throw new Error("Configure a senha administrativa nas propriedades do projeto.");
  }

  return password;
}

function createSession(tipo, nome) {
  cleanupExpiredSessions();
  const token = `${Utilities.getUuid()}${Utilities.getUuid()}`.replace(/-/g, "");
  const expiresAt = Date.now() + SESSION_DURATION_HOURS * 60 * 60 * 1000;
  const key = `SESSION_${hashPassword(token)}`;
  PropertiesService.getScriptProperties().setProperty(key, JSON.stringify({ tipo, nome, expiresAt }));

  return { tipo, nome, token, expiresAt };
}

function cleanupExpiredSessions() {
  const properties = PropertiesService.getScriptProperties();
  const all = properties.getProperties();

  Object.keys(all).filter(key => key.indexOf("SESSION_") === 0).forEach(key => {
    try {
      const sessionData = JSON.parse(all[key]);
      if (!sessionData.expiresAt || Date.now() > Number(sessionData.expiresAt)) properties.deleteProperty(key);
    } catch (error) {
      properties.deleteProperty(key);
    }
  });
}

function requireSession(params) {
  const token = String(params && params.sessionToken || "").trim();

  if (!token) {
    throw new Error("Sua sessao expirou. Entre novamente.");
  }

  const key = `SESSION_${hashPassword(token)}`;
  const raw = PropertiesService.getScriptProperties().getProperty(key);

  if (!raw) {
    throw new Error("Sua sessao expirou. Entre novamente.");
  }

  const actor = JSON.parse(raw);

  if (!actor.expiresAt || Date.now() > Number(actor.expiresAt)) {
    PropertiesService.getScriptProperties().deleteProperty(key);
    throw new Error("Sua sessao expirou. Entre novamente.");
  }

  if (actor.tipo === "participante") {
    const person = getPersonByName(actor.nome);

    if (!person || !person.ativo) {
      throw new Error("Participante removido da lista.");
    }
  }

  return { tipo: actor.tipo, nome: actor.nome };
}

function getAuthorizedState(params) {
  const actor = requireSession(params);
  return getState({ actor });
}

function getActorLabel(params) {
  try {
    return requireSession(params).nome;
  } catch (error) {
    return "";
  }
}

function stateParamsForActor(actor, params) {
  return { actor };
}

function authenticateParticipant(nome, senha) {
  const person = getPersonByName(nome);

  if (!person || !person.ativo) {
    throw new Error("Participante nao encontrado.");
  }

  if (!person.senhaHash) {
    throw new Error("A senha ainda nao foi cadastrada. Faca login primeiro.");
  }

  const passwordHash = person.senhaSalt
    ? hashPassword(`${person.senhaSalt}:${String(senha || "")}`)
    : hashPassword(senha);

  if (person.senhaHash !== passwordHash) {
    throw new Error("Senha incorreta.");
  }

  return person;
}

function closeExpiredVotes() {
  getVotesMeta()
    .filter(vote => vote.status === "aberta" && isVoteExpired(vote))
    .forEach(vote => finalizeVote(vote, "automatico"));
}

function isVoteExpired(vote) {
  const endDate = getVoteEndDate(vote);
  return endDate && new Date() >= endDate;
}

function getVoteEndDate(vote) {
  if (!vote || !vote.criadoEm) return null;

  const createdAt = parseVoteDate(vote.criadoEm);

  if (!createdAt) return null;

  return new Date(createdAt.getTime() + VOTE_DURATION_MINUTES * 60 * 1000);
}

function parseVoteDate(value) {
  if (Object.prototype.toString.call(value) === "[object Date]") {
    return Number.isNaN(value.getTime()) ? null : value;
  }

  const text = String(value || "").trim();
  const brMatch = text.match(/^(\d{2})\/(\d{2})\/(\d{4})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/);

  if (brMatch) {
    const parsed = new Date(
      Number(brMatch[3]),
      Number(brMatch[2]) - 1,
      Number(brMatch[1]),
      Number(brMatch[4]),
      Number(brMatch[5]),
      Number(brMatch[6] || 0)
    );
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }

  const parsed = new Date(text);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function getPeople() {
  return readRows(SHEETS.pessoas)
    .map((row, index) => ({
      id: row.id,
      nome: row.nome,
      ordem: Number(row.ordem),
      ativo: row.ativo === true || String(row.ativo).toLowerCase() === "true",
      criadoEm: row.criadoEm,
      senhaHash: row.senhaHash || "",
      pausado: row.pausado === true || String(row.pausado).toLowerCase() === "true",
      codigoAtivacaoHash: row.codigoAtivacaoHash || "",
      senhaSalt: row.senhaSalt || "",
      row: index + 2
    }))
    .filter(person => person.nome)
    .sort((a, b) => a.ordem - b.ordem);
}

function getActivePeople() {
  return getPeople().filter(person => person.ativo && !person.pausado);
}

function getPersonByName(nome) {
  const cleanName = String(nome || "").trim().toLowerCase();
  if (!cleanName) return null;

  return getPeople().find(person => person.nome.toLowerCase() === cleanName) || null;
}

function getActiveVote() {
  return getVotesMeta()
    .filter(vote => vote.status === "aberta")
    .sort((a, b) => b.row - a.row)[0] || null;
}

function getVotesMeta() {
  return readRows(SHEETS.votacoes)
    .map((row, index) => ({
      id: row.id,
      status: String(row.status || "").toLowerCase(),
      criadoEm: row.criadoEm,
      encerradoEm: row.encerradoEm,
      resultado: row.resultado,
      motivo: row.motivo || "Compra extra",
      elegiveis: parseJsonArray(row.elegiveis),
      criadoPor: row.criadoPor || "",
      row: index + 2
    }))
    .filter(vote => vote.id);
}

function getVotesFor(voteId) {
  return readRows(SHEETS.votos)
    .map((row, index) => ({
      votacaoId: row.votacaoId,
      pessoa: row.pessoa,
      voto: String(row.voto || "").toLowerCase(),
      data: row.data,
      row: index + 2
    }))
    .filter(item => item.votacaoId === voteId && item.pessoa);
}

function getHistory() {
  return readRows(SHEETS.historico)
    .filter(row => row.data || row.texto)
    .map(row => ({
      data: formatDate(row.data),
      tipo: row.tipo || "",
      texto: row.texto || "",
      pagador: row.pagador || "",
      ator: row.ator || "",
      detalhes: parseJsonObject(row.detalhes)
    }));
}

function getPurchaseStats() {
  const purchases = readRows(SHEETS.historico)
    .filter(row => {
      const type = String(row.tipo || "").trim().toLowerCase();
      const text = String(row.texto || "").trim().toLowerCase();
      return type === "compra" || (type === "entrada" && text.indexOf("pagou o energetico") !== -1);
    })
    .map(row => ({
      data: normalizeDateKey(row.data),
      nome: String(row.pagador || "Sem responsavel").trim() || "Sem responsavel"
    }));

  readRows(SHEETS.movimentacoes)
    .filter(row => (
      String(row.tipo || "").trim().toLowerCase() === "compra" &&
      (row.desfeito === true || String(row.desfeito).toLowerCase() === "true")
    ))
    .forEach(row => {
      const payer = String(row.pessoa || "Sem responsavel").trim() || "Sem responsavel";
      const dateKey = normalizeDateKey(row.data);
      let index = -1;

      for (let position = purchases.length - 1; position >= 0; position -= 1) {
        if (purchases[position].nome === payer && purchases[position].data === dateKey) {
          index = position;
          break;
        }
      }

      if (index === -1) {
        for (let position = purchases.length - 1; position >= 0; position -= 1) {
          if (purchases[position].nome === payer) {
            index = position;
            break;
          }
        }
      }

      if (index !== -1) purchases.splice(index, 1);
    });

  const counts = {};
  const records = {};

  purchases.forEach(item => {
    counts[item.nome] = (counts[item.nome] || 0) + 1;
    const recordKey = `${item.data}|${item.nome}`;
    records[recordKey] = (records[recordKey] || 0) + 1;
  });

  const byPerson = Object.keys(counts)
    .map(name => ({ nome: name, quantidade: counts[name] }))
    .filter(item => item.quantidade > 0)
    .sort((a, b) => b.quantidade - a.quantidade || a.nome.localeCompare(b.nome));
  const quantity = byPerson.reduce((total, item) => total + item.quantidade, 0);

  return {
    quantidade: quantity,
    precoUnitario: ENERGY_UNIT_PRICE,
    valorTotal: quantity * ENERGY_UNIT_PRICE,
    litrosPorUnidade: ENERGY_UNIT_LITERS,
    volumeTotalLitros: quantity * ENERGY_UNIT_LITERS,
    porPessoa: byPerson,
    registros: Object.keys(records).map(key => {
      const separator = key.indexOf("|");
      return {
        data: key.slice(0, separator),
        nome: key.slice(separator + 1),
        quantidade: records[key]
      };
    }).sort((a, b) => a.data.localeCompare(b.data) || a.nome.localeCompare(b.nome))
  };
}

function addHistory(tipo, texto, pagador, ator, detalhes) {
  getSheet(SHEETS.historico).appendRow([
    new Date(),
    tipo,
    texto,
    pagador || "",
    ator || "",
    detalhes ? JSON.stringify(detalhes) : ""
  ]);
}

function parseJsonArray(value) {
  if (Array.isArray(value)) return value;
  if (!value) return [];

  try {
    const parsed = JSON.parse(String(value));
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    return [];
  }
}

function parseJsonObject(value) {
  if (value && typeof value === "object" && Object.prototype.toString.call(value) !== "[object Date]") return value;
  if (!value) return {};

  try {
    const parsed = JSON.parse(String(value));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (error) {
    return {};
  }
}

function updatePersonOrder(row, order) {
  getSheet(SHEETS.pessoas).getRange(row, 3).setValue(order);
}

function hashPassword(password) {
  const bytes = Utilities.computeDigest(
    Utilities.DigestAlgorithm.SHA_256,
    String(password || ""),
    Utilities.Charset.UTF_8
  );

  return bytes.map(byte => {
    const value = byte < 0 ? byte + 256 : byte;
    return (`0${value.toString(16)}`).slice(-2);
  }).join("");
}

function ensureSheet(ss, name, headers) {
  const sheet = ss.getSheetByName(name) || ss.insertSheet(name);
  const currentHeaders = sheet.getRange(1, 1, 1, Math.max(headers.length, 1)).getValues()[0];
  const needsHeaders = headers.some((header, index) => currentHeaders[index] !== header);

  if (needsHeaders) {
    sheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    sheet.setFrozenRows(1);
  }

  return sheet;
}

function getSheet(name) {
  return SpreadsheetApp.getActiveSpreadsheet().getSheetByName(name);
}

function readRows(sheetName) {
  const sheet = getSheet(sheetName);
  const values = sheet.getDataRange().getValues();

  if (values.length < 2) return [];

  const headers = values[0];

  return values.slice(1).map(row => {
    const item = {};

    headers.forEach((header, index) => {
      item[header] = row[index];
    });

    return item;
  });
}

function clearSheet(sheetName, headers) {
  const sheet = getSheet(sheetName);
  sheet.clear();
  sheet.getRange(1, 1, 1, headers.length).setValues([headers]);
  sheet.setFrozenRows(1);
}

function parseBody(e) {
  if (!e || !e.postData || !e.postData.contents) return {};

  try {
    return JSON.parse(e.postData.contents);
  } catch (error) {
    return e.parameter || {};
  }
}

function getParam(e, name) {
  return e && e.parameter ? e.parameter[name] : "";
}

function formatDate(value) {
  if (!value) return "";

  if (Object.prototype.toString.call(value) === "[object Date]") {
    return Utilities.formatDate(value, Session.getScriptTimeZone(), "dd/MM/yyyy HH:mm:ss");
  }

  return String(value);
}

function jsonResponse(payload) {
  return ContentService
    .createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}

function apiResponse(callback, payload) {
  if (callback) {
    return ContentService
      .createTextOutput(`${callback}(${JSON.stringify(payload)});`)
      .setMimeType(ContentService.MimeType.JAVASCRIPT);
  }

  return jsonResponse(payload);
}

function scriptResponse(requestId, payload) {
  const safeRequestId = JSON.stringify(requestId || "");
  const safePayload = JSON.stringify(payload);
  const js = `
(function () {
  if (window.__energyManagerReceive) {
    window.__energyManagerReceive({
      source: "energy-manager",
      requestId: ${safeRequestId},
      payload: ${safePayload}
    });
  }
})();`;

  return ContentService
    .createTextOutput(js)
    .setMimeType(ContentService.MimeType.JAVASCRIPT);
}

function bridgeResponse(requestId, payload) {
  const safeRequestId = JSON.stringify(requestId || "");
  const safePayload = JSON.stringify(payload);
  const visiblePayload = escapeHtml(JSON.stringify(payload, null, 2));
  const html = `
<!doctype html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    body { font-family: Arial, sans-serif; padding: 24px; color: #111827; }
    pre { white-space: pre-wrap; word-break: break-word; background: #f3f4f6; padding: 16px; border-radius: 8px; }
  </style>
</head>
<body>
<h1>Bridge OK</h1>
<p>Esta pagina tambem enviou a resposta para o app.</p>
<pre>${visiblePayload}</pre>
<script>
  var message = {
    source: "energy-manager",
    requestId: ${safeRequestId},
    payload: ${safePayload}
  };

  function sendTo(target) {
    try {
      if (target) target.postMessage(message, "*");
    } catch (error) {}
  }

  function notifyApp() {
    sendTo(window.parent);
    sendTo(window.top);
    try { sendTo(window.parent.parent); } catch (error) {}
    try { sendTo(window.parent.parent.parent); } catch (error) {}
  }

  notifyApp();
  setTimeout(notifyApp, 50);
  setTimeout(notifyApp, 250);
  setTimeout(notifyApp, 1000);
</script>
</body>
</html>`;

  return HtmlService
    .createHtmlOutput(html)
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function errorResponse(error) {
  return jsonResponse({
    ok: false,
    error: error.message || String(error)
  });
}
