const CONFIG = {
    API_URL: window.location.origin + '/api',
    REFRESH_INTERVAL: 60000,
    INACTIVITY_TIMEOUT: 120000,
    CACHE_KEY: 'directory-data'
};

const state = {
    companies: [],
    individuals: [],
    buildingInfoContent: '',
    backgroundImage: '',
    dataVersion: 0,
    currentScreen: 'main-menu',
    inactivityTimer: null
};

async function init() {
    loadCachedData();
    await Promise.all([refreshData(), loadKioskLocationLine()]);
    setInterval(checkForUpdates, CONFIG.REFRESH_INTERVAL);
    setupInactivityDetection();
}

async function refreshData() {
    try {
        const [companies, individuals, backgroundData, buildingInfo] = await Promise.all([
            fetch(`${CONFIG.API_URL}/companies`).then(r => {
                if (!r.ok) throw new Error(r.status);
                return r.json();
            }),
            fetch(`${CONFIG.API_URL}/individuals`).then(r => {
                if (!r.ok) throw new Error(r.status);
                return r.json();
            }),
            fetch(`${CONFIG.API_URL}/background-image`).then(r => {
                if (!r.ok) throw new Error(r.status);
                return r.json();
            }),
            fetch(`${CONFIG.API_URL}/building-info`).then(r => {
                if (!r.ok) throw new Error(r.status);
                return r.json();
            }).catch(() => '')
        ]);

        state.companies = companies;
        state.individuals = individuals;
        state.buildingInfoContent = typeof buildingInfo === 'string' ? buildingInfo : '';

        if (backgroundData.filename) {
            state.backgroundImage = backgroundData.filename;
            applyBackgroundImage(backgroundData.filename);
        }
        applyBuildingInfoContent(state.buildingInfoContent);

        localStorage.setItem(CONFIG.CACHE_KEY, JSON.stringify(state));

        if (state.currentScreen === 'companies') displayCompanies(state.companies);
        if (state.currentScreen === 'individuals') displayIndividuals(state.individuals);

        return true;
    } catch (error) {
        console.error('Failed to refresh data:', error);
        return false;
    }
}

async function checkForUpdates() {
    try {
        const response = await fetch(`${CONFIG.API_URL}/data-version`);
        const { version } = await response.json();
        if (version > state.dataVersion) {
            state.dataVersion = version;
            await refreshData();
        }
    } catch (error) {
        // noop
    }
}

function applyBackgroundImage(filename) {
    if (!filename) return;
    const url = `url('/${filename}')`;
    ['main-menu', 'companies', 'individuals', 'building-info'].forEach(id => {
        const el = document.getElementById(id);
        if (el) {
            el.style.backgroundImage = url;
        }
    });
}

function loadCachedData() {
    const cached = localStorage.getItem(CONFIG.CACHE_KEY);
    if (!cached) return;

    try {
        const data = JSON.parse(cached);
        state.companies = data.companies || [];
        state.individuals = data.individuals || [];
        state.buildingInfoContent = data.buildingInfoContent || '';
        state.backgroundImage = data.backgroundImage || '';
        state.dataVersion = data.dataVersion || 0;
        if (state.backgroundImage) applyBackgroundImage(state.backgroundImage);
        applyBuildingInfoContent(state.buildingInfoContent);
    } catch {
        localStorage.removeItem(CONFIG.CACHE_KEY);
    }
}

function applyBuildingInfoContent(content) {
    const el = document.getElementById('building-info-content');
    if (!el) return;
    if (!el.dataset.defaultHtml) {
        el.dataset.defaultHtml = el.innerHTML;
    }
    const html = (content || '').trim();
    el.innerHTML = html || el.dataset.defaultHtml;
}

function showScreen(screenId) {
    document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
    const target = document.getElementById(screenId);
    if (target) target.classList.add('active');

    state.currentScreen = screenId;

    if (screenId === 'companies') {
        displayCompanies(state.companies);
    } else if (screenId === 'individuals') {
        displayIndividuals(state.individuals);
    }

    updateScrollButtons('companies-list');
    updateScrollButtons('individuals-list');

    resetInactivityTimer();
}

function openSearch(type) {
    const wrapId = type === 'company' ? 'company-search-wrap' : 'individual-search-wrap';
    const inputId = type === 'company' ? 'company-search' : 'individual-search';

    const wrap = document.getElementById(wrapId);
    const input = document.getElementById(inputId);

    if (!wrap || !input) return;

    wrap.classList.remove('hidden');
    input.focus();
    resetInactivityTimer();
}

function listAll(type) {
    if (type === 'company') {
        const input = document.getElementById('company-search');
        if (input) input.value = '';
        displayCompanies(state.companies);
    } else {
        const input = document.getElementById('individual-search');
        if (input) input.value = '';
        displayIndividuals(state.individuals);
    }

    resetInactivityTimer();
}

function searchCompanies(query) {
    const q = query.trim().toLowerCase();
    const filtered = state.companies.filter(company =>
        company.name.toLowerCase().includes(q) ||
        company.building.toLowerCase().includes(q) ||
        company.suite.toLowerCase().includes(q)
    );
    displayCompanies(filtered);
    resetInactivityTimer();
}

function searchIndividuals(query) {
    const q = query.trim().toLowerCase();
    const filtered = state.individuals.filter(person =>
        person.first_name.toLowerCase().includes(q) ||
        person.last_name.toLowerCase().includes(q) ||
        person.building.toLowerCase().includes(q) ||
        person.suite.toLowerCase().includes(q)
    );
    displayIndividuals(filtered);
    resetInactivityTimer();
}

function displayCompanies(companies) {
    const container = document.getElementById('companies-list');
    if (!container) return;

    if (companies.length === 0) {
        container.innerHTML = '<div class="result-row"><div class="result-name">No companies found</div><div></div><div></div></div>';
        updateScrollButtons('companies-list');
        return;
    }

    const rows = companies
        .slice()
        .sort((a, b) => a.name.localeCompare(b.name))
        .map(company => {
            return `<div class="result-row">
                <div class="result-name">${escapeHtml(company.name)}</div>
                <div class="result-suite">${escapeHtml(company.suite)}</div>
                <div class="result-building">${escapeHtml(company.building)}</div>
            </div>`;
        });

    container.innerHTML = rows.join('');
    container.scrollTop = 0;
    updateScrollButtons('companies-list');
}

function displayIndividuals(individuals) {
    const container = document.getElementById('individuals-list');
    if (!container) return;

    if (individuals.length === 0) {
        container.innerHTML = '<div class="result-row"><div class="result-name">No individuals found</div><div></div><div></div></div>';
        updateScrollButtons('individuals-list');
        return;
    }

    const rows = individuals
        .slice()
        .sort((a, b) => {
            const byLast = a.last_name.localeCompare(b.last_name);
            return byLast !== 0 ? byLast : a.first_name.localeCompare(b.first_name);
        })
        .map(person => {
            return `<div class="result-row">
                <div class="result-name">${escapeHtml(person.last_name)}, ${escapeHtml(person.first_name)}</div>
                <div class="result-suite">${escapeHtml(person.suite)}</div>
                <div class="result-building">${escapeHtml(person.building)}</div>
            </div>`;
        });

    container.innerHTML = rows.join('');
    container.scrollTop = 0;
    updateScrollButtons('individuals-list');
}

function scrollResults(listId, direction) {
    const list = document.getElementById(listId);
    if (!list) return;

    const amount = Math.max(180, Math.floor(list.clientHeight * 0.42));
    list.scrollBy({ top: direction * amount, behavior: 'smooth' });
    setTimeout(() => updateScrollButtons(listId), 220);
    resetInactivityTimer();
}

function updateScrollButtons(listId) {
    const list = document.getElementById(listId);
    if (!list) return;

    const controls = list.parentElement && list.parentElement.querySelector('.scroll-controls');
    if (!controls) return;

    const [upBtn, downBtn] = controls.querySelectorAll('.scroll-btn');
    if (!upBtn || !downBtn) return;

    const maxScroll = Math.max(0, list.scrollHeight - list.clientHeight);
    const atTop = list.scrollTop <= 2;
    const atBottom = list.scrollTop >= maxScroll - 2;
    const noScrollNeeded = maxScroll <= 2;

    upBtn.disabled = noScrollNeeded || atTop;
    downBtn.disabled = noScrollNeeded || atBottom;
}

function setupScrollControls() {
    ['companies-list', 'individuals-list'].forEach((id) => {
        const list = document.getElementById(id);
        if (!list) return;
        list.addEventListener('scroll', () => updateScrollButtons(id), { passive: true });
        updateScrollButtons(id);
    });
}

function setupInactivityDetection() {
    ['mousedown', 'touchstart', 'keydown'].forEach(event => {
        document.addEventListener(event, resetInactivityTimer);
    });

    resetInactivityTimer();
}

function resetInactivityTimer() {
    if (state.inactivityTimer) clearTimeout(state.inactivityTimer);

    state.inactivityTimer = setTimeout(() => {
        if (state.currentScreen !== 'main-menu') {
            showScreen('main-menu');
            const c = document.getElementById('company-search');
            const i = document.getElementById('individual-search');
            if (c) c.value = '';
            if (i) i.value = '';
        }
    }, CONFIG.INACTIVITY_TIMEOUT);
}

async function loadKioskLocationLine() {
    const line = document.getElementById('welcome-building-line');
    if (!line) return;

    try {
        const response = await fetch(`${CONFIG.API_URL}/kiosk-location`);
        if (!response.ok) throw new Error(response.status);

        const data = await response.json();
        line.textContent = data && data.buildingCode ? `Building ${data.buildingCode}` : 'Building 430x';
    } catch {
        line.textContent = 'Building 430x';
    }
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

window.openSearch = openSearch;
window.listAll = listAll;
window.showScreen = showScreen;
window.searchCompanies = searchCompanies;
window.searchIndividuals = searchIndividuals;
window.scrollResults = scrollResults;

window.addEventListener('DOMContentLoaded', () => {
    setupScrollControls();
    init();
});
