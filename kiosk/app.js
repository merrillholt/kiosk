const CONFIG = {
    API_URL: window.location.origin + '/api',
    REFRESH_INTERVAL: 60000,
    INACTIVITY_TIMEOUT: 120000,
    CACHE_KEY: 'directory-data'
};

const state = {
    companies: [],
    individuals: [],
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
        const [companies, individuals, bgData] = await Promise.all([
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
            })
        ]);

        state.companies = companies;
        state.individuals = individuals;

        if (bgData.filename) {
            state.backgroundImage = bgData.filename;
            applyBackgroundImage(bgData.filename);
        }

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
        state.backgroundImage = data.backgroundImage || '';
        state.dataVersion = data.dataVersion || 0;
        if (state.backgroundImage) applyBackgroundImage(state.backgroundImage);
    } catch {
        localStorage.removeItem(CONFIG.CACHE_KEY);
    }
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
        return;
    }

    const rows = companies
        .slice()
        .sort((a, b) => a.name.localeCompare(b.name))
        .map(company => {
            const isThisBuilding = String(company.building) === '4301' || String(company.building) === '4305' || String(company.building) === '4309';
            return `<div class="result-row">
                <div class="result-name">${escapeHtml(company.name)}</div>
                <div class="result-suite">${escapeHtml(company.suite)}</div>
                <div class="result-building">${isThisBuilding ? 'This Bldg' : escapeHtml(company.building)}</div>
            </div>`;
        });

    container.innerHTML = rows.join('');
}

function displayIndividuals(individuals) {
    const container = document.getElementById('individuals-list');
    if (!container) return;

    if (individuals.length === 0) {
        container.innerHTML = '<div class="result-row"><div class="result-name">No individuals found</div><div></div><div></div></div>';
        return;
    }

    const rows = individuals
        .slice()
        .sort((a, b) => {
            const byLast = a.last_name.localeCompare(b.last_name);
            return byLast !== 0 ? byLast : a.first_name.localeCompare(b.first_name);
        })
        .map(person => {
            const isThisBuilding = String(person.building) === '4301' || String(person.building) === '4305' || String(person.building) === '4309';
            return `<div class="result-row">
                <div class="result-name">${escapeHtml(person.last_name)}, ${escapeHtml(person.first_name)}</div>
                <div class="result-suite">${escapeHtml(person.suite)}</div>
                <div class="result-building">${isThisBuilding ? 'This Bldg' : escapeHtml(person.building)}</div>
            </div>`;
        });

    container.innerHTML = rows.join('');
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

window.addEventListener('DOMContentLoaded', init);
