const CONFIG = {
    API_URL: window.location.origin + '/api',
    REFRESH_INTERVAL: 60000,
    INACTIVITY_TIMEOUT: 120000,
    CACHE_KEY: 'directory-data'
};

let state = {
    companies: [],
    individuals: [],
    buildingInfo: '',
    dataVersion: 0,
    currentScreen: 'main-menu',
    inactivityTimer: null
};

async function init() {
    console.log('Initializing directory kiosk...');
    loadCachedData();
    await refreshData();
    setInterval(checkForUpdates, CONFIG.REFRESH_INTERVAL);
    setupInactivityDetection();
    createKeyboard('keyboard-company', 'company-search');
    createKeyboard('keyboard-individual', 'individual-search');
    console.log('Kiosk initialized successfully');
}

async function refreshData() {
    try {
        const [companies, individuals, buildingInfo] = await Promise.all([
            fetch(`${CONFIG.API_URL}/companies`).then(r => r.json()),
            fetch(`${CONFIG.API_URL}/individuals`).then(r => r.json()),
            fetch(`${CONFIG.API_URL}/building-info`).then(r => r.json())
        ]);
        
        state.companies = companies;
        state.individuals = individuals;
        state.buildingInfo = buildingInfo;
        
        localStorage.setItem(CONFIG.CACHE_KEY, JSON.stringify(state));
        
        console.log('Data refreshed:', {
            companies: companies.length,
            individuals: individuals.length
        });
        
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
            console.log('New data available, refreshing...');
            await refreshData();
            state.dataVersion = version;
        }
    } catch (error) {
        console.error('Failed to check for updates:', error);
    }
}

function loadCachedData() {
    const cached = localStorage.getItem(CONFIG.CACHE_KEY);
    if (cached) {
        const data = JSON.parse(cached);
        state.companies = data.companies || [];
        state.individuals = data.individuals || [];
        state.buildingInfo = data.buildingInfo || '';
        console.log('Loaded cached data');
    }
}

function showScreen(screenId) {
    document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
    document.getElementById(screenId).classList.add('active');
    state.currentScreen = screenId;
    
    if (screenId === 'companies') {
        displayCompanies(state.companies);
    } else if (screenId === 'individuals') {
        displayIndividuals(state.individuals);
    } else if (screenId === 'building-info') {
        displayBuildingInfo();
    }
    
    resetInactivityTimer();
}

function searchCompanies(query) {
    const filtered = state.companies.filter(company => 
        company.name.toLowerCase().includes(query.toLowerCase()) ||
        company.building.toLowerCase().includes(query.toLowerCase()) ||
        company.suite.toLowerCase().includes(query.toLowerCase())
    );
    displayCompanies(filtered);
    resetInactivityTimer();
}

function searchIndividuals(query) {
    const filtered = state.individuals.filter(person => 
        person.first_name.toLowerCase().includes(query.toLowerCase()) ||
        person.last_name.toLowerCase().includes(query.toLowerCase()) ||
        person.building.toLowerCase().includes(query.toLowerCase()) ||
        person.suite.toLowerCase().includes(query.toLowerCase())
    );
    displayIndividuals(filtered);
    resetInactivityTimer();
}

function displayCompanies(companies) {
    const container = document.getElementById('companies-list');
    
    if (companies.length === 0) {
        container.innerHTML = '<div class="no-results">No companies found</div>';
        return;
    }
    
    container.innerHTML = companies
        .sort((a, b) => a.name.localeCompare(b.name))
        .map(company => `
            <div class="result-item">
                <div class="result-name">${escapeHtml(company.name)}</div>
                <div class="result-details">
                    <span class="result-building">Building ${escapeHtml(company.building)}</span>
                    <span class="result-suite">Suite ${escapeHtml(company.suite)}</span>
                    ${company.phone ? `<div style="margin-top: 10px;">📞 ${escapeHtml(company.phone)}</div>` : ''}
                </div>
            </div>
        `).join('');
}

function displayIndividuals(individuals) {
    const container = document.getElementById('individuals-list');
    
    if (individuals.length === 0) {
        container.innerHTML = '<div class="no-results">No individuals found</div>';
        return;
    }
    
    container.innerHTML = individuals
        .sort((a, b) => {
            const lastNameCompare = a.last_name.localeCompare(b.last_name);
            return lastNameCompare !== 0 ? lastNameCompare : a.first_name.localeCompare(b.first_name);
        })
        .map(person => `
            <div class="result-item">
                <div class="result-name">${escapeHtml(person.last_name)}, ${escapeHtml(person.first_name)}</div>
                <div class="result-details">
                    ${person.title ? `<div>${escapeHtml(person.title)}</div>` : ''}
                    <span class="result-building">Building ${escapeHtml(person.building)}</span>
                    <span class="result-suite">Suite ${escapeHtml(person.suite)}</span>
                    ${person.phone ? `<div style="margin-top: 10px;">📞 ${escapeHtml(person.phone)}</div>` : ''}
                </div>
            </div>
        `).join('');
}

function displayBuildingInfo() {
    const container = document.getElementById('building-info-content');
    container.innerHTML = state.buildingInfo || '<div>No building information available</div>';
}

function createKeyboard(containerId, inputId) {
    const keys = [
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
        'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T',
        'U', 'V', 'W', 'X', 'Y', 'Z', '0', '1', '2', '3',
        '4', '5', '6', '7', '8', '9', 'SPACE', 'CLEAR'
    ];
    
    const container = document.getElementById(containerId);
    
    container.innerHTML = keys.map(key => {
        const isWide = key === 'SPACE' || key === 'CLEAR';
        return `<button class="key ${isWide ? 'wide' : ''}" 
                        onclick="handleKey('${inputId}', '${key}')">${key}</button>`;
    }).join('');
}

function handleKey(inputId, key) {
    const input = document.getElementById(inputId);
    
    if (key === 'CLEAR') {
        input.value = '';
    } else if (key === 'SPACE') {
        input.value += ' ';
    } else {
        input.value += key;
    }
    
    input.dispatchEvent(new Event('input'));
    resetInactivityTimer();
}

function setupInactivityDetection() {
    const events = ['mousedown', 'touchstart', 'keydown'];
    events.forEach(event => {
        document.addEventListener(event, resetInactivityTimer);
    });
    resetInactivityTimer();
}

function resetInactivityTimer() {
    if (state.inactivityTimer) {
        clearTimeout(state.inactivityTimer);
    }
    
    state.inactivityTimer = setTimeout(() => {
        if (state.currentScreen !== 'main-menu') {
            showScreen('main-menu');
            document.getElementById('company-search').value = '';
            document.getElementById('individual-search').value = '';
        }
    }, CONFIG.INACTIVITY_TIMEOUT);
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

window.addEventListener('DOMContentLoaded', init);
