import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "hosts-ssh"

    // Cached home directory
    property string homeDir: Qt.getenv("HOME")

    // Cache file path
    property string cacheFilePath: homeDir + "/.cache/dms-hosts-ssh-repos.json"

    // Settings
    property string terminal: pluginData.terminal || "foot"
    property string sshUser: pluginData.sshUser || ""
    property string hostsFile: pluginData.hostsFile || "/etc/hosts"
    property string hostPrefix: pluginData.hostPrefix || "m-"
    property string cloneDirectory: pluginData.cloneDirectory || ""
    property string repoSearchPrefix: pluginData.repoSearchPrefix || "!"

    // Computed clone directory (fallback to home)
    property string cloneDir: cloneDirectory || homeDir

    // State
    property var hostsList: []
    property int hostCount: hostsList.length
    property string searchQuery: ""

    // Cached canonical hostnames (first alias per unique IP) — rebuilt when hostsList changes
    property var canonicalHosts: new Set()
    onHostsListChanged: {
        let ipToHost = {};
        for (let host of hostsList) {
            if (!ipToHost[host.ip]) ipToHost[host.ip] = host.name;
        }
        canonicalHosts = new Set(Object.values(ipToHost));
    }
    
    // Repo search mode
    property bool isRepoSearch: searchQuery.startsWith(repoSearchPrefix) && repoSearchPrefix !== ""
    property string repoSearchQuery: isRepoSearch ? searchQuery.slice(repoSearchPrefix.length).toLowerCase() : ""
    
    // Shared delegate heights for scroll calculations
    readonly property int hostDelegateHeight: 48
    readonly property int repoDelegateHeight: 44

    // Trigger fetching all repos when entering repo search mode
    onIsRepoSearchChanged: {
        if (isRepoSearch) {
            fetchAllHostRepos();
        }
    }
    
    // Git repos state: { "hostname": { loading: bool, repos: [], error: string, expanded: bool } }
    property var gitReposState: ({})

    // Cached repo stats (avoids O(n) reduce on every state change in UI bindings)
    property int totalRepoCount: 0
    property int searchedHostCount: 0

    onGitReposStateChanged: {
        // Update cached stats
        let repos = 0;
        let hosts = 0;
        for (let h in gitReposState) {
            hosts++;
            const s = gitReposState[h];
            if (s.repos) repos += s.repos.length;
        }
        totalRepoCount = repos;
        searchedHostCount = hosts;
        // Refresh repo search results
        if (isRepoSearch) repoSearchDebounce.restart();
    }
    
    // Save repos cache to file
    function saveReposCache() {
        // Build cache object with only repos data (not loading/expanded state)
        let cache = {};
        for (let hostname in gitReposState) {
            const state = gitReposState[hostname];
            if (state.repos && state.repos.length > 0) {
                cache[hostname] = state.repos;
            }
        }
        
        const jsonData = JSON.stringify(cache);
        repoCacheSaver.jsonData = jsonData;
        repoCacheSaver.running = true;
    }
    
    // Load repos cache from file
    function loadReposCache() {
        repoCacheLoader.running = true;
    }
    
    // Process to save cache (uses stdin to avoid shell injection)
    Process {
        id: repoCacheSaver
        property string jsonData: ""

        command: ["tee", root.cacheFilePath]

        stdinEnabled: true

        onStarted: {
            write(jsonData + "\n");
            stdinClose();
        }

        onExited: (exitCode) => {
            if (exitCode !== 0) {
                console.log("Failed to save repos cache");
            }
        }
    }
    
    // Process to load cache
    Process {
        id: repoCacheLoader
        property string output: ""

        command: ["cat", root.cacheFilePath]

        stdout: SplitParser {
            onRead: line => { repoCacheLoader.output += line; }
        }

        onExited: (exitCode) => {
            if (exitCode === 0 && output) {
                try {
                    const cache = JSON.parse(output);
                    let newState = {};
                    for (let hostname in cache) {
                        newState[hostname] = {
                            loading: false,
                            repos: cache[hostname],
                            error: "",
                            expanded: false
                        };
                    }
                    root.gitReposState = newState;
                    // Check existence of all cached repos
                    for (let hostname in cache) {
                        if (cache[hostname].length > 0) {
                            root.checkAllReposExist(hostname, cache[hostname]);
                        }
                    }
                } catch (e) {
                    console.log("Failed to parse repos cache: " + e);
                }
            }
            output = "";
        }
    }

    // Save cache (debounced) - only call when repo data actually changes, not on UI state changes
    Timer {
        id: cacheSaveTimer
        interval: 2000
        onTriggered: root.saveReposCache()
    }

    function scheduleCacheSave() {
        cacheSaveTimer.restart();
    }
    
    // Track which repos already exist in clone directory (keyed by folder name)
    property var existingRepos: ({})

    // Derive the on-disk folder name from a repo path (e.g. "group/project.git" -> "project")
    function repoFolder(repoName) {
        return repoName.split("/").pop().replace(/\.git$/, "");
    }

    // Check if a repo exists in the clone directory (single repo, e.g. after clone)
    function checkRepoExists(hostname, repoName, forceRecheck) {
        const key = repoFolder(repoName);
        if (!forceRecheck && existingRepos.hasOwnProperty(key)) return;
        // Remove stale entry so checkAllReposExist's filter won't skip it
        if (forceRecheck && existingRepos.hasOwnProperty(key)) {
            let updated = Object.assign({}, existingRepos);
            delete updated[key];
            existingRepos = updated;
        }
        checkAllReposExist(hostname, [repoName]);
    }

    // Queue of repos pending existence check
    property var repoCheckQueue: []

    // Batch-check all repos for a host in a single process invocation
    function checkAllReposExist(hostname, repos) {
        if (repos.length === 0) return;
        // Filter out already-checked repos and add to queue
        let toCheck = repos.filter(r => !existingRepos.hasOwnProperty(repoFolder(r)));
        if (toCheck.length === 0) return;
        repoCheckQueue = repoCheckQueue.concat(toCheck);
        processRepoCheckQueue();
    }

    function processRepoCheckQueue() {
        if (repoExistsChecker.running || repoCheckQueue.length === 0) return;

        // Deduplicate by folder name
        let seen = new Set();
        let batch = [];
        for (let r of repoCheckQueue) {
            const folder = repoFolder(r);
            if (!seen.has(folder) && !existingRepos.hasOwnProperty(folder)) {
                seen.add(folder);
                batch.push(r);
            }
        }
        repoCheckQueue = [];
        if (batch.length === 0) return;

        repoExistsChecker.checkRepos = batch;
        repoExistsChecker.output = "";

        const cloneDir = root.cloneDir;
        let checks = batch.map(r => {
            return 'test -d "' + cloneDir + '/' + repoFolder(r) + '" && echo Y || echo N';
        }).join("; ");
        repoExistsChecker.command = ["sh", "-c", checks];
        repoExistsChecker.running = true;
    }

    Process {
        id: repoExistsChecker
        property var checkRepos: []
        property string output: ""

        stdout: SplitParser {
            onRead: line => { repoExistsChecker.output += line.trim() + "\n"; }
        }

        onExited: (exitCode) => {
            const lines = output.trim().split("\n");
            let newExisting = Object.assign({}, root.existingRepos);
            for (let i = 0; i < checkRepos.length; i++) {
                const key = root.repoFolder(checkRepos[i]);
                newExisting[key] = (i < lines.length && lines[i] === "Y");
            }
            root.existingRepos = newExisting;
            output = "";
            // Process any queued checks that arrived while running
            root.processRepoCheckQueue();
        }
    }
    
    // Function to fetch git repos for a host
    function fetchGitRepos(hostname) {
        let newState = Object.assign({}, gitReposState);

        // Check if we're toggling off an already expanded host
        if (newState[hostname] && newState[hostname].repos && newState[hostname].repos.length > 0) {
            if (newState[hostname].expanded) {
                // Collapsing this host - reset repo selection and focus host
                newState[hostname] = Object.assign({}, newState[hostname], { expanded: false });
                gitReposState = newState;
                expandedCount = Math.max(0, expandedCount - 1);

                // Find the index of this host for focusing
                for (let i = 0; i < filteredHosts.length; i++) {
                    if (filteredHosts[i].name === hostname) {
                        popoutColumn.selectedIndex = i;
                        break;
                    }
                }
                popoutColumn.selectedRepoIndex = -1;
                return;
            }
        }

        // Collapse all other expanded hosts first
        for (let h in newState) {
            if (h !== hostname) {
                newState[h] = Object.assign({}, newState[h], { expanded: false });
            }
        }

        // Check if already loaded
        if (newState[hostname] && newState[hostname].repos && newState[hostname].repos.length > 0) {
            // Expand this host
            newState[hostname] = Object.assign({}, newState[hostname], { expanded: true });
            gitReposState = newState;
            expandedCount = 1;
            scrollToHostAfterExpand(hostname);
            return;
        }

        // Start loading
        newState[hostname] = { loading: true, repos: [], error: "", expanded: true };
        gitReposState = newState;
        expandedCount = 1;

        // Find a free fetcher from the pool
        for (let i = 0; i < repoFetcherPool.count; i++) {
            const fetcher = repoFetcherPool.objectAt(i);
            if (!fetcher.running) {
                fetcher.startFetch(hostname, false);
                break;
            }
        }

        scrollToHostAfterExpand(hostname);
    }
    
    // Scroll to host after expanding its repo list
    function scrollToHostAfterExpand(hostname) {
        scrollToHostTimer.targetHostname = hostname;
        scrollToHostTimer.restart();
    }
    
    Timer {
        id: scrollToHostTimer
        property string targetHostname: ""
        interval: 50
        onTriggered: {
            if (!targetHostname) return;
            
            // Find the index of this host
            let hostIndex = -1;
            for (let i = 0; i < root.filteredHosts.length; i++) {
                if (root.filteredHosts[i].name === targetHostname) {
                    hostIndex = i;
                    break;
                }
            }
            
            if (hostIndex >= 0) {
                // Force layout update
                hostListView.forceLayout();
                
                // Since all other repos are collapsed, calculate Y position
                const hostHeight = root.hostDelegateHeight;
                const spacing = hostListView.spacing;
                
                const yPos = hostIndex * (hostHeight + spacing);
                hostListView.contentY = Math.max(0, yPos);
            }
        }
    }
    
    // Explicit expanded count — avoids iterating all state on every change
    property int expandedCount: 0
    property bool hasExpandedRepos: expandedCount > 0

    // Function to collapse all expanded repo views
    function collapseAllRepos() {
        let newState = Object.assign({}, gitReposState);
        for (let hostname in newState) {
            if (newState[hostname].expanded) {
                newState[hostname] = Object.assign({}, newState[hostname], { expanded: false });
            }
        }
        gitReposState = newState;
        expandedCount = 0;
    }
    
    // Track active clone operations: { "hostname:repoName": true }
    property var activeClones: ({})
    
    // Clone queue: [{hostname, repoName, cloneUrl}, ...]
    property var cloneQueue: []
    
    // Function to clone a repo (runs in background)
    function cloneGitRepo(hostname, repoName) {
        const cloneKey = repoFolder(repoName);

        // Prevent duplicate clones
        if (activeClones[cloneKey]) {
            ToastService.showInfo("Already cloning " + repoName, "");
            return;
        }

        // Mark as active
        let newActive = Object.assign({}, activeClones);
        newActive[cloneKey] = true;
        activeClones = newActive;

        // Add to queue
        let newQueue = cloneQueue.slice();
        newQueue.push({
            hostname: hostname,
            repoName: repoName,
            cloneUrl: "git@" + hostname + ":" + repoName
        });
        cloneQueue = newQueue;
        
        ToastService.showInfo("Cloning: " + repoName, "");
        
        // Start processing if not already running
        if (!gitCloneProcess.running) {
            processNextClone();
        }
    }
    
    function processNextClone() {
        if (cloneQueue.length === 0) return;

        const item = cloneQueue[0];
        gitCloneProcess.hostname = item.hostname;
        gitCloneProcess.repoName = item.repoName;
        gitCloneProcess.cloneUrl = item.cloneUrl;
        gitCloneProcess.errorLines = [];
        gitCloneProcess.running = true;
    }
    
    function onCloneFinished(hostname, repoName, success, errorMsg) {
        const cloneKey = repoFolder(repoName);
        
        // Remove from active clones
        let newActive = Object.assign({}, activeClones);
        delete newActive[cloneKey];
        activeClones = newActive;
        
        // Remove from queue
        let newQueue = cloneQueue.slice();
        newQueue.shift();
        cloneQueue = newQueue;
        
        // Show result notification
        if (success) {
            ToastService.showInfo("Cloned: " + repoName, "");
            // Refresh the repo exists check (force recheck)
            checkRepoExists(hostname, repoName, true);
        } else {
            ToastService.showInfo("Clone failed: " + repoName, errorMsg || "");
        }
        
        // Process next in queue
        processNextClone();
    }
    
    // Background git clone process
    Process {
        id: gitCloneProcess

        property string hostname: ""
        property string repoName: ""
        property string cloneUrl: ""
        property var errorLines: []

        command: ["git", "clone", cloneUrl]
        workingDirectory: root.cloneDir

        stderr: SplitParser {
            onRead: line => {
                let lines = gitCloneProcess.errorLines.slice();
                lines.push(line);
                gitCloneProcess.errorLines = lines;
            }
        }

        onExited: (exitCode) => {
            const success = (exitCode === 0);
            let errorMsg = "";

            if (!success && errorLines.length > 0) {
                for (let line of errorLines) {
                    if (line.includes("fatal:") || line.includes("error:")) {
                        errorMsg = line.replace(/^(fatal:|error:)\s*/, "").trim();
                        break;
                    }
                }
                if (!errorMsg) {
                    errorMsg = errorLines[errorLines.length - 1];
                }
            }

            root.onCloneFinished(hostname, repoName, success, errorMsg);
        }
    }
    
    // Queue for fetching repos from all hosts
    property var repoFetchQueue: []
    property bool isFetchingAllRepos: false
    property int maxConcurrentFetchers: 8

    // Parse SSH output into repo names
    function parseRepoOutput(output) {
        const lines = output.trim().split("\n").filter(l => l.trim());
        let repos = [];
        for (let line of lines) {
            // Skip common non-repo lines
            if (line.includes("Welcome") || line.includes("hello") ||
                line.includes("PTY") || line.includes("interactive") ||
                line.includes("Hi ") || line.includes("You've successfully")) {
                continue;
            }
            // Format: "R W\treponame" or "R\treponame" or just "reponame"
            let match = line.match(/^[RW\s]+\t(.+)$/);
            if (match) {
                repos.push(match[1].trim());
            } else if (line.match(/^[\w\-\.\/]+$/)) {
                repos.push(line.trim());
            }
        }
        return repos;
    }

    // Handle completed fetch for a host
    function onRepoFetchCompleted(hostname, output, isGlobalFetch) {
        let newState = Object.assign({}, root.gitReposState);
        const repos = parseRepoOutput(output);
        const shouldExpand = !isGlobalFetch;

        if (repos.length > 0) {
            newState[hostname] = { loading: false, repos: repos, error: "", expanded: shouldExpand };
            root.gitReposState = newState;
            root.checkAllReposExist(hostname, repos);
            root.scheduleCacheSave();
        } else {
            newState[hostname] = { loading: false, repos: [], error: "No repos found or access denied", expanded: shouldExpand };
            root.gitReposState = newState;
        }

        // Defer next pool fill so the exiting process fully resets before reuse
        if (isGlobalFetch && root.isFetchingAllRepos) {
            fillPoolTimer.restart();
        }
    }

    Timer {
        id: fillPoolTimer
        interval: 0  // next event loop tick
        onTriggered: root.fillFetcherPool()
    }

    // Force re-fetch repos from all hosts (clears cache first)
    function refreshAllRepos() {
        // Wait for current fetches to finish
        if (isFetchingAllRepos) return;

        // Clear all cached repo data
        gitReposState = {};
        existingRepos = {};
        repoFetchQueue = [];

        // Re-fetch
        fetchAllHostRepos();
    }

    // Fetch repos from all hosts (for global repo search)
    function fetchAllHostRepos() {
        if (isFetchingAllRepos) return;

        // Build queue of canonical hosts that haven't been fetched yet
        let queue = [];
        for (let host of hostsList) {
            if (!canonicalHosts.has(host.name)) continue;
            const state = gitReposState[host.name];
            if (state && (state.repos.length > 0 || state.loading || state.error)) {
                continue;
            }
            queue.push(host.name);
        }

        if (queue.length === 0) return;

        repoFetchQueue = queue;
        isFetchingAllRepos = true;
        fillFetcherPool();
    }

    // Fill the fetcher pool with work from the queue
    function fillFetcherPool() {
        if (repoFetchQueue.length === 0) {
            // Check if all fetchers are done
            let anyRunning = false;
            for (let i = 0; i < repoFetcherPool.count; i++) {
                if (repoFetcherPool.objectAt(i).running) {
                    anyRunning = true;
                    break;
                }
            }
            if (!anyRunning) isFetchingAllRepos = false;
            return;
        }

        // Batch: collect all hosts to start, then do a single state update
        let hostsToStart = [];
        let queue = repoFetchQueue.slice();
        for (let i = 0; i < repoFetcherPool.count && queue.length > 0; i++) {
            const fetcher = repoFetcherPool.objectAt(i);
            if (!fetcher.running) {
                hostsToStart.push({ fetcher: fetcher, hostname: queue.shift() });
            }
        }
        repoFetchQueue = queue;

        if (hostsToStart.length > 0) {
            // Single state update for all new hosts
            let newState = Object.assign({}, gitReposState);
            for (let item of hostsToStart) {
                newState[item.hostname] = { loading: true, repos: [], error: "", expanded: false };
            }
            gitReposState = newState;

            // Start all fetchers after state is updated
            for (let item of hostsToStart) {
                item.fetcher.startFetch(item.hostname, true);
            }
        }
    }

    // Pool of concurrent repo fetcher processes
    Instantiator {
        id: repoFetcherPool
        model: root.maxConcurrentFetchers

        Process {
            id: fetcherInstance
            property string hostname: ""
            property string output: ""
            property bool isGlobalFetch: false

            function startFetch(host, global) {
                hostname = host;
                isGlobalFetch = global;
                output = "";
                command = ["ssh", "-o", "ConnectTimeout=2", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "git@" + host];
                running = true;
            }

            stdout: SplitParser {
                onRead: line => {
                    fetcherInstance.output += line + "\n";
                }
            }

            stderr: SplitParser {
                onRead: line => {
                    fetcherInstance.output += line + "\n";
                }
            }

            onExited: (exitCode) => {
                root.onRepoFetchCompleted(hostname, output, isGlobalFetch);
                output = "";
                isGlobalFetch = false;
            }
        }
    }

    // Filtered hosts based on search (empty in repo search mode)
    property var filteredHosts: {
        if (isRepoSearch) return [];
        if (!searchQuery.trim()) return hostsList;
        const query = searchQuery.toLowerCase();
        return hostsList.filter(host => 
            host.name.toLowerCase().includes(query) || 
            host.ip.toLowerCase().includes(query)
        );
    }
    
    // Debounced filtered repos for repo search mode
    property var filteredRepos: []

    // Recompute filtered repos (called by debounce timer)
    function recomputeFilteredRepos() {
        if (!isRepoSearch || repoSearchQuery === "") {
            filteredRepos = [];
            return;
        }

        let results = [];
        let seenRepos = new Set();
        for (let hostname in gitReposState) {
            const state = gitReposState[hostname];
            if (!state.repos || state.repos.length === 0) continue;
            // Skip non-canonical aliases to avoid duplicate repos
            if (!canonicalHosts.has(hostname)) continue;
            for (let repoName of state.repos) {
                if (seenRepos.has(repoName)) continue;
                if (repoName.toLowerCase().includes(repoSearchQuery)) {
                    seenRepos.add(repoName);
                    results.push({
                        hostname: hostname,
                        repoName: repoName,
                        repoKey: repoFolder(repoName)
                    });
                }
            }
        }
        filteredRepos = results;
    }

    onRepoSearchQueryChanged: repoSearchDebounce.restart()

    Timer {
        id: repoSearchDebounce
        interval: 150
        onTriggered: root.recomputeFilteredRepos()
    }

    // Parse /etc/hosts on load and periodically (infrequent background refresh)
    Timer {
        id: refreshTimer
        interval: 120000 // Refresh every 2 minutes in background
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: hostsReader.running = true
    }

    Process {
        id: hostsReader

        // Unified awk script with prefix passed as variable (literal string match, no regex issues)
        command: {
            const prefix = root.hostPrefix ? root.hostPrefix.trim() : "";
            const awkScript = `awk -v prefix="${prefix}" '
                /^[[:space:]]*#/ { next }
                /^[[:space:]]*$/ { next }
                {
                    ip = $1
                    for (i = 2; i <= NF; i++) {
                        if ($i ~ /^#/) break
                        if (prefix == "" || substr($i, 1, length(prefix)) == prefix) {
                            print $i "|" ip
                        }
                    }
                }
            ' "${root.hostsFile}" | sort -u`;
            return ["sh", "-c", awkScript];
        }

        property string output: ""

        stdout: SplitParser {
            onRead: line => {
                if (line.trim()) hostsReader.output += line.trim() + "\n";
            }
        }

        onExited: (exitCode) => {
            if (exitCode === 0 && output) {
                const hosts = output.trim().split("\n").map(line => {
                    const parts = line.split("|");
                    return { name: parts[0] || "", ip: parts[1] || "" };
                }).filter(h => h.name);
                root.hostsList = hosts;
            }
            output = "";
        }
    }

    // SSH connection function
    function connectToHost(hostname) {
        const sshTarget = (root.sshUser ? root.sshUser + "@" : "") + hostname;

        if (root.terminal === "kitty") {
            kittyPidFinder.sshTarget = sshTarget;
            kittyPidFinder.hostname = hostname;
            kittyPidFinder.running = true;
        } else {
            Quickshell.execDetached(buildTerminalCommand(sshTarget));
            ToastService.showInfo("SSH", "Connecting to " + hostname);
        }
    }

    // Build the shell command that runs SSH with a "press enter to exit" prompt
    function buildSshCmd(sshTarget) {
        return "ssh " + sshTarget + "; echo; echo 'Connection closed. Press Enter to exit.'; read";
    }

    // Launch a new kitty window (fallback when no socket/tab support)
    function launchKittyWindow(hostname, sshTarget) {
        Quickshell.execDetached(["kitty", "--title", hostname, "sh", "-c", buildSshCmd(sshTarget)]);
        ToastService.showInfo("SSH", "Connecting to " + hostname);
    }

    function buildTerminalCommand(sshTarget) {
        const fullCmd = buildSshCmd(sshTarget);
        switch (root.terminal) {
            case "foot":       return ["foot", "-e", "sh", "-c", fullCmd];
            case "alacritty":  return ["alacritty", "-e", "sh", "-c", fullCmd];
            case "wezterm":    return ["wezterm", "start", "--", "sh", "-c", fullCmd];
            case "gnome-terminal": return ["gnome-terminal", "--", "sh", "-c", fullCmd];
            case "konsole":    return ["konsole", "-e", "sh", "-c", fullCmd];
            default:           return [root.terminal, "-e", "sh", "-c", fullCmd];
        }
    }

    // Kitty socket base name from settings (without PID)
    property string kittySocketBase: pluginData.kittySocket || "unix:@mykitty"

    // Kitty tab support: pgrep → check socket → launch tab (or fallback to new window)
    Process {
        id: kittyPidFinder
        property string sshTarget: ""
        property string hostname: ""
        property string kittyPid: ""

        command: ["pgrep", "-x", "kitty"]

        stdout: SplitParser {
            onRead: line => { if (line.trim()) kittyPidFinder.kittyPid = line.trim(); }
        }

        onExited: (exitCode) => {
            if (exitCode === 0 && kittyPid) {
                kittyChecker.sshTarget = sshTarget;
                kittyChecker.hostname = hostname;
                kittyChecker.kittyPid = kittyPid;
                kittyChecker.running = true;
            } else {
                root.launchKittyWindow(hostname, sshTarget);
            }
            kittyPid = "";
        }
    }

    Process {
        id: kittyChecker
        property string sshTarget: ""
        property string hostname: ""
        property string kittyPid: ""

        command: ["kitty", "@", "--to", root.kittySocketBase + "-" + kittyPid, "ls"]

        onExited: (exitCode) => {
            if (exitCode === 0) {
                kittyLauncher.sshTarget = sshTarget;
                kittyLauncher.hostname = hostname;
                kittyLauncher.kittyPid = kittyPid;
                kittyLauncher.running = true;
            } else {
                root.launchKittyWindow(hostname, sshTarget);
            }
        }
    }

    Process {
        id: kittyLauncher
        property string sshTarget: ""
        property string hostname: ""
        property string kittyPid: ""

        command: [
            "kitty", "@", "--to", root.kittySocketBase + "-" + kittyPid,
            "launch", "--type=tab", "--tab-title", hostname,
            "sh", "-c", root.buildSshCmd(sshTarget)
        ]

        onExited: (exitCode) => {
            if (exitCode === 0) {
                ToastService.showInfo("SSH", "Opening " + hostname + " in kitty tab");
                kittyFocuser.kittyPid = kittyPid;
                kittyFocuser.running = true;
            } else {
                root.launchKittyWindow(hostname, sshTarget);
            }
        }
    }

    Process {
        id: kittyFocuser
        property string kittyPid: ""
        command: ["kitty", "@", "--to", root.kittySocketBase + "-" + kittyPid, "focus-window"]
    }

    // Bar pill for horizontal bar
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "terminal"
                size: root.iconSize
                color: root.hostCount > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.hostCount.toString()
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // Bar pill for vertical bar
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "terminal"
                size: root.iconSize
                color: root.hostCount > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.hostCount.toString()
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // Popout content with search and list
    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn

            headerText: "SSH Hosts"
            detailsText: root.hostPrefix ? 
                root.hostCount + " hosts with '" + root.hostPrefix + "' prefix" :
                root.hostCount + " hosts"
            showCloseButton: false

            // Track selected index for keyboard navigation
            property int selectedIndex: -1
            // Track selected repo index (-1 means host is selected, >= 0 means repo at that index)
            property int selectedRepoIndex: -1
            
            // Helper to get the currently selected host's repo state
            function getSelectedHostRepoState() {
                if (selectedIndex < 0 || selectedIndex >= root.filteredHosts.length) return null;
                const hostname = root.filteredHosts[selectedIndex].name;
                return root.gitReposState[hostname] || null;
            }
            
            // Helper to check if selected host has expanded repos
            function selectedHostHasExpandedRepos() {
                const state = getSelectedHostRepoState();
                return state && state.expanded && state.repos && state.repos.length > 0;
            }
            
            // Scroll to ensure the selected repo is visible
            function ensureRepoVisible() {
                if (selectedIndex < 0 || selectedRepoIndex < 0) return;
                
                // Get the delegate item
                const delegateItem = hostListView.itemAtIndex(selectedIndex);
                if (!delegateItem) return;
                
                // Calculate the Y position of the selected repo within the list
                const hostHeight = root.hostDelegateHeight;
                const repoHeight = root.repoDelegateHeight;
                const spacing = Theme.spacingS;
                
                const repoY = delegateItem.y + hostHeight + spacing + (selectedRepoIndex * (repoHeight + spacing));
                const repoBottom = repoY + repoHeight;
                
                // Check if repo is below visible area
                if (repoBottom > hostListView.contentY + hostListView.height) {
                    hostListView.contentY = repoBottom - hostListView.height + spacing;
                }
                // Check if repo is above visible area
                else if (repoY < hostListView.contentY) {
                    hostListView.contentY = repoY - spacing;
                }
            }
            
            // Trigger scroll after repo selection changes
            onSelectedRepoIndexChanged: {
                if (selectedRepoIndex >= 0) {
                    scrollTimer.restart();
                }
            }
            
            Timer {
                id: scrollTimer
                interval: 10
                onTriggered: popoutColumn.ensureRepoVisible()
            }

            // Reset selection when filtered hosts change
            onVisibleChanged: {
                if (visible) {
                    selectedIndex = -1;
                    selectedRepoIndex = -1;
                    // Collapse all repo lists
                    root.collapseAllRepos();
                    // Refresh hosts on open
                    hostsReader.running = true;
                    // Focus search field when popout opens
                    focusTimer.start();
                }
            }

            Timer {
                id: focusTimer
                interval: 50
                onTriggered: searchField.forceActiveFocus()
            }

            // Search box
            Item {
                width: parent.width
                height: searchField.height + Theme.spacingM

                StyledRect {
                    id: searchBox
                    anchors.fill: parent
                    anchors.margins: Theme.spacingXS
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.color: searchField.activeFocus ? Theme.primary : "transparent"
                    border.width: searchField.activeFocus ? 2 : 0

                    Behavior on border.color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                    Behavior on border.width { NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                    Row {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "search"
                            size: Theme.iconSizeSmall
                            color: searchField.activeFocus ? Theme.primary : Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter

                            Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                        }

                        TextInput {
                            id: searchField
                            width: parent.width - Theme.iconSizeSmall - Theme.spacingS * 2 - clearButton.width
                            height: Theme.fontSizeMedium + Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            clip: true
                            selectByMouse: true

                            property string placeholderText: "Search hosts (" + root.repoSearchPrefix + " for repos)..."

                            Text {
                                anchors.fill: parent
                                text: searchField.placeholderText
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeMedium
                                visible: !searchField.text && !searchField.activeFocus
                            }

                            onTextChanged: {
                                root.searchQuery = text;
                                if (root.isRepoSearch) {
                                    popoutColumn.selectedIndex = root.filteredRepos.length > 0 ? 0 : -1;
                                } else {
                                    popoutColumn.selectedIndex = root.filteredHosts.length > 0 ? 0 : -1;
                                }
                                popoutColumn.selectedRepoIndex = -1;
                            }

                            Keys.onEscapePressed: (event) => {
                                if (event.modifiers & Qt.ShiftModifier) {
                                    // Shift+Escape: clear search and show full list
                                    text = "";
                                    root.searchQuery = "";
                                    popoutColumn.selectedIndex = root.filteredHosts.length > 0 ? 0 : -1;
                                    popoutColumn.selectedRepoIndex = -1;
                                } else if (popoutColumn.selectedRepoIndex >= 0) {
                                    // Escape while in repo list: exit repo selection
                                    popoutColumn.selectedRepoIndex = -1;
                                } else if (text) {
                                    // Escape with text: clear search
                                    text = "";
                                } else {
                                    // Escape without text: close popout
                                    popoutColumn.closePopout();
                                }
                            }

                            Keys.onReturnPressed: (event) => {
                                // In repo search mode
                                if (root.isRepoSearch) {
                                    if (popoutColumn.selectedIndex >= 0 && popoutColumn.selectedIndex < root.filteredRepos.length) {
                                        const repo = root.filteredRepos[popoutColumn.selectedIndex];
                                        if (!root.existingRepos[repo.repoKey] && !root.activeClones[repo.repoKey]) {
                                            root.cloneGitRepo(repo.hostname, repo.repoName);
                                        }
                                    }
                                    event.accepted = true;
                                    return;
                                }
                                
                                // Super+Return when repo is selected: clone the repo
                                if ((event.modifiers & Qt.MetaModifier) && popoutColumn.selectedRepoIndex >= 0) {
                                    if (popoutColumn.selectedHostHasExpandedRepos()) {
                                        const hostname = root.filteredHosts[popoutColumn.selectedIndex].name;
                                        const state = popoutColumn.getSelectedHostRepoState();
                                        const repoName = state.repos[popoutColumn.selectedRepoIndex];
                                        const folderKey = root.repoFolder(repoName);
                                        // Only clone if not already cloned and not currently cloning
                                        if (!root.existingRepos[folderKey] && !root.activeClones[folderKey]) {
                                            root.cloneGitRepo(hostname, repoName);
                                        }
                                    }
                                    event.accepted = true;
                                    return;
                                }
                                
                                // Super+Return on host: fetch/toggle git repos
                                if (event.modifiers & Qt.MetaModifier) {
                                    if (popoutColumn.selectedIndex >= 0 && popoutColumn.selectedIndex < root.filteredHosts.length) {
                                        root.fetchGitRepos(root.filteredHosts[popoutColumn.selectedIndex].name);
                                    }
                                    event.accepted = true;
                                    return;
                                }
                                
                                // Plain Return: connect SSH (only if not in repo selection mode)
                                if (popoutColumn.selectedRepoIndex < 0) {
                                    if (popoutColumn.selectedIndex >= 0 && popoutColumn.selectedIndex < root.filteredHosts.length) {
                                        root.connectToHost(root.filteredHosts[popoutColumn.selectedIndex].name);
                                        popoutColumn.closePopout();
                                    } else if (root.filteredHosts.length === 1) {
                                        root.connectToHost(root.filteredHosts[0].name);
                                        popoutColumn.closePopout();
                                    }
                                }
                            }

                            Keys.onDownPressed: {
                                // Repo search mode navigation
                                if (root.isRepoSearch) {
                                    if (root.filteredRepos.length > 0) {
                                        popoutColumn.selectedIndex = Math.min(
                                            popoutColumn.selectedIndex + 1,
                                            root.filteredRepos.length - 1
                                        );
                                        repoSearchListView.positionViewAtIndex(popoutColumn.selectedIndex, ListView.Contain);
                                    }
                                    return;
                                }
                                
                                if (root.filteredHosts.length === 0) return;
                                
                                // If we're in a repo list, navigate within it
                                if (popoutColumn.selectedRepoIndex >= 0 && popoutColumn.selectedHostHasExpandedRepos()) {
                                    const state = popoutColumn.getSelectedHostRepoState();
                                    if (popoutColumn.selectedRepoIndex < state.repos.length - 1) {
                                        // Move to next repo
                                        popoutColumn.selectedRepoIndex++;
                                    } else {
                                        // Exit repo list, move to next host
                                        popoutColumn.selectedRepoIndex = -1;
                                        if (popoutColumn.selectedIndex < root.filteredHosts.length - 1) {
                                            popoutColumn.selectedIndex++;
                                            hostListView.positionViewAtIndex(popoutColumn.selectedIndex, ListView.Contain);
                                        }
                                    }
                                } else if (popoutColumn.selectedHostHasExpandedRepos()) {
                                    // Enter the repo list
                                    popoutColumn.selectedRepoIndex = 0;
                                } else {
                                    // Move to next host
                                    popoutColumn.selectedIndex = Math.min(
                                        popoutColumn.selectedIndex + 1,
                                        root.filteredHosts.length - 1
                                    );
                                    popoutColumn.selectedRepoIndex = -1;
                                    hostListView.positionViewAtIndex(popoutColumn.selectedIndex, ListView.Contain);
                                }
                            }

                            Keys.onUpPressed: {
                                // Repo search mode navigation
                                if (root.isRepoSearch) {
                                    if (root.filteredRepos.length > 0) {
                                        popoutColumn.selectedIndex = Math.max(
                                            popoutColumn.selectedIndex - 1,
                                            0
                                        );
                                        repoSearchListView.positionViewAtIndex(popoutColumn.selectedIndex, ListView.Contain);
                                    }
                                    return;
                                }
                                
                                if (root.filteredHosts.length === 0) return;
                                
                                // If we're in a repo list, navigate within it
                                if (popoutColumn.selectedRepoIndex > 0) {
                                    popoutColumn.selectedRepoIndex--;
                                } else if (popoutColumn.selectedRepoIndex === 0) {
                                    // Exit repo list, back to host
                                    popoutColumn.selectedRepoIndex = -1;
                                } else {
                                    // Check if previous host has expanded repos
                                    if (popoutColumn.selectedIndex > 0) {
                                        popoutColumn.selectedIndex--;
                                        hostListView.positionViewAtIndex(popoutColumn.selectedIndex, ListView.Contain);
                                        
                                        // If the new host has expanded repos, jump to last repo
                                        if (popoutColumn.selectedHostHasExpandedRepos()) {
                                            const state = popoutColumn.getSelectedHostRepoState();
                                            popoutColumn.selectedRepoIndex = state.repos.length - 1;
                                        }
                                    }
                                }
                            }

                            Keys.onTabPressed: {
                                if (root.filteredHosts.length > 0) {
                                    popoutColumn.selectedIndex = (popoutColumn.selectedIndex + 1) % root.filteredHosts.length;
                                    popoutColumn.selectedRepoIndex = -1;
                                    hostListView.positionViewAtIndex(popoutColumn.selectedIndex, ListView.Contain);
                                }
                            }
                        }

                        DankIcon {
                            id: clearButton
                            name: "close"
                            size: Theme.iconSizeSmall
                            color: searchField.text ? Theme.surfaceText : "transparent"
                            anchors.verticalCenter: parent.verticalCenter
                            visible: searchField.text !== ""

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    searchField.text = "";
                                    searchField.forceActiveFocus();
                                }
                            }
                        }
                    }
                }
            }

            // Show All button when search is active
            Item {
                width: parent.width
                height: root.searchQuery ? showAllButton.height + Theme.spacingS : 0
                visible: root.searchQuery !== ""

                Behavior on height { NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                StyledRect {
                    id: showAllButton
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - Theme.spacingM
                    height: 40
                    radius: Theme.cornerRadius
                    color: showAllMouse.containsMouse ? Theme.primaryContainer : Theme.surfaceContainerHighest

                    Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "format_list_bulleted"
                            size: Theme.iconSizeSmall
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "Show all " + root.hostCount + " hosts"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: showAllMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            searchField.text = "";
                            root.searchQuery = "";
                            searchField.forceActiveFocus();
                        }
                    }
                }
            }

            // Collapse All button when repos are expanded
            Item {
                width: parent.width
                height: root.hasExpandedRepos ? collapseAllButton.height + Theme.spacingS : 0
                visible: root.hasExpandedRepos

                Behavior on height { NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                StyledRect {
                    id: collapseAllButton
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - Theme.spacingM
                    height: 40
                    radius: Theme.cornerRadius
                    color: collapseAllMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer

                    Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "unfold_less"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "Collapse all repos"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: collapseAllMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.collapseAllRepos();
                            popoutColumn.selectedRepoIndex = -1;
                        }
                    }
                }
            }

            // Host list (hidden in repo search mode)
            Item {
                width: parent.width
                visible: !root.isRepoSearch
                implicitHeight: root.isRepoSearch ? 0 : (root.popoutHeight - popoutColumn.headerHeight - 
                               popoutColumn.detailsHeight - 60 - Theme.spacingXL -
                               (root.searchQuery ? 48 : 0) -
                               (root.hasExpandedRepos ? 48 : 0))

                ListView {
                    id: hostListView
                    anchors.fill: parent
                    anchors.margins: Theme.spacingS
                    clip: true
                    spacing: Theme.spacingS
                    model: root.filteredHosts

                    delegate: Column {
                        id: hostDelegateColumn
                        width: hostListView.width
                        spacing: Theme.spacingS
                        
                        property var hostData: modelData
                        property var repoState: root.gitReposState[modelData.name] || { loading: false, repos: [], error: "", expanded: false }
                        property bool isExpanded: repoState.expanded && (repoState.repos.length > 0 || repoState.loading || repoState.error)
                        
                        StyledRect {
                            id: hostDelegate
                            width: parent.width
                            height: root.hostDelegateHeight
                            radius: Theme.cornerRadius

                            property bool isSelected: index === popoutColumn.selectedIndex

                            color: isSelected ? Theme.primaryContainer :
                                   hostMouse.containsMouse ? Theme.surfaceContainerHighest :
                                   Theme.surfaceContainerHigh

                            border.width: isSelected ? 2 : 0
                            border.color: Theme.primary

                            Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                            Behavior on border.width { NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "computer"
                                    size: Theme.iconSize
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter

                                    Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2
                                    width: parent.width - Theme.iconSize - gitIcon.width - Theme.spacingM * 3

                                    StyledText {
                                        text: hostDelegateColumn.hostData.name
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText

                                        Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                    }

                                    StyledText {
                                        text: hostDelegateColumn.hostData.ip
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText

                                        Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                    }
                                }
                                
                                DankIcon {
                                    id: gitIcon
                                    name: hostDelegateColumn.repoState.loading ? "sync" :
                                          hostDelegateColumn.isExpanded ? "expand_less" : "expand_more"
                                    size: Theme.iconSizeSmall
                                    color: gitIconMouse.containsMouse ? Theme.primary : Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter

                                    Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                                    RotationAnimator on rotation {
                                        from: 0
                                        to: 360
                                        duration: 1000
                                        loops: Animation.Infinite
                                        running: hostDelegateColumn.repoState.loading
                                    }
                                    
                                    MouseArea {
                                        id: gitIconMouse
                                        anchors.fill: parent
                                        anchors.margins: -Theme.spacingS
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: (mouse) => {
                                            mouse.accepted = true;
                                            root.fetchGitRepos(hostDelegateColumn.hostData.name);
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                id: hostMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton

                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.RightButton) {
                                        // Right-click: fetch git repos
                                        root.fetchGitRepos(hostDelegateColumn.hostData.name);
                                    } else {
                                        // Left-click: connect SSH
                                        root.connectToHost(hostDelegateColumn.hostData.name);
                                        popoutColumn.closePopout();
                                    }
                                }
                                
                                onEntered: {
                                    popoutColumn.selectedIndex = index;
                                }
                            }
                            
                            // Handle Super+Enter for git repos
                            Keys.onPressed: (event) => {
                                if (event.key === Qt.Key_Return && 
                                    (event.modifiers & Qt.MetaModifier)) {
                                    root.fetchGitRepos(hostDelegateColumn.hostData.name);
                                    event.accepted = true;
                                }
                            }
                        }
                        
                        // Expanded repos section
                        Column {
                            id: reposColumn
                            width: parent.width - Theme.spacingM
                            anchors.right: parent.right
                            spacing: Theme.spacingS
                            visible: hostDelegateColumn.isExpanded
                            
                            // Loading indicator
                            StyledRect {
                                visible: hostDelegateColumn.repoState.loading
                                width: parent.width
                                height: root.repoDelegateHeight
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainer
                                
                                Row {
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingS
                                    
                                    DankIcon {
                                        name: "sync"
                                        size: Theme.iconSizeSmall
                                        color: Theme.surfaceVariantText
                                        
                                        RotationAnimator on rotation {
                                            from: 0
                                            to: 360
                                            duration: 1000
                                            loops: Animation.Infinite
                                            running: hostDelegateColumn.repoState.loading
                                        }
                                    }
                                    
                                    StyledText {
                                        text: "Fetching repos..."
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }
                            
                            // Error message
                            StyledRect {
                                visible: !hostDelegateColumn.repoState.loading && hostDelegateColumn.repoState.error
                                width: parent.width
                                height: root.repoDelegateHeight
                                radius: Theme.cornerRadius
                                color: Theme.errorContainer
                                
                                StyledText {
                                    anchors.centerIn: parent
                                    text: hostDelegateColumn.repoState.error
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.onErrorContainer
                                }
                            }
                            
                            // Repos list
                            Repeater {
                                model: hostDelegateColumn.repoState.repos || []
                                
                                StyledRect {
                                    id: repoItem
                                    width: reposColumn.width
                                    height: root.repoDelegateHeight
                                    radius: Theme.cornerRadius

                                    property string repoKey: root.repoFolder(modelData)
                                    property bool repoExists: root.existingRepos[repoKey] === true
                                    property bool isCloning: root.activeClones[repoKey] === true
                                    property bool isSelected: index === popoutColumn.selectedRepoIndex &&
                                                              hostDelegateColumn.hostData.name === root.filteredHosts[popoutColumn.selectedIndex]?.name

                                    color: isSelected ? Theme.secondaryContainer :
                                           repoMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
                                    border.width: isSelected ? 2 : 0
                                    border.color: Theme.secondary

                                    Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                    Behavior on border.width { NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: Theme.spacingM
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: repoItem.repoExists ? "check_circle" : (repoItem.isCloning ? "sync" : "folder")
                                            size: Theme.iconSizeSmall
                                            color: repoItem.repoExists ? Theme.primary : (repoItem.isCloning ? Theme.secondary : Theme.surfaceVariantText)
                                            anchors.verticalCenter: parent.verticalCenter

                                            Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                            
                                            // Rotate animation for cloning state
                                            RotationAnimation on rotation {
                                                running: repoItem.isCloning
                                                from: 0
                                                to: 360
                                                duration: 1000
                                                loops: Animation.Infinite
                                            }
                                        }
                                        
                                        StyledText {
                                            id: repoNameText
                                            text: modelData + (repoItem.isCloning ? " (cloning...)" : "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: repoItem.isCloning ? Theme.secondary : Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                            elide: Text.ElideMiddle
                                            width: parent.width - Theme.iconSizeSmall - ((repoItem.repoExists || repoItem.isCloning) ? 0 : cloneRepoIcon.width + Theme.spacingS) - Theme.spacingS * 2
                                        }
                                        
                                        DankIcon {
                                            id: cloneRepoIcon
                                            visible: !repoItem.repoExists && !repoItem.isCloning
                                            name: "download"
                                            size: Theme.iconSizeSmall
                                            color: cloneRepoMouse.containsMouse ? Theme.primary : Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter

                                            Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                            
                                            MouseArea {
                                                id: cloneRepoMouse
                                                anchors.fill: parent
                                                anchors.margins: -Theme.spacingXS
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: (mouse) => {
                                                    mouse.accepted = true;
                                                    root.cloneGitRepo(hostDelegateColumn.hostData.name, modelData);
                                                }
                                            }
                                        }
                                    }
                                    
                                    MouseArea {
                                        id: repoMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: (repoItem.repoExists || repoItem.isCloning) ? Qt.ArrowCursor : Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton
                                        
                                        onClicked: {
                                            if (!repoItem.repoExists && !repoItem.isCloning) {
                                                root.cloneGitRepo(hostDelegateColumn.hostData.name, modelData);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Empty state for hosts
                    Item {
                        anchors.centerIn: parent
                        visible: root.filteredHosts.length === 0 && !root.isRepoSearch
                        width: parent.width
                        height: emptyColumn.height

                        Column {
                            id: emptyColumn
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            DankIcon {
                                name: root.searchQuery ? "search_off" : "dns"
                                size: 48
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            StyledText {
                                text: root.searchQuery ? 
                                      "No matching hosts" : 
                                      (root.hostPrefix ? "No '" + root.hostPrefix + "' hosts found" : "No hosts found")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            StyledText {
                                visible: !root.searchQuery
                                text: "Add entries to " + root.hostsFile
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }
            }
            
            // Repo search toolbar (visible only in repo search mode)
            Item {
                width: parent.width
                height: root.isRepoSearch ? repoToolbar.height + Theme.spacingS : 0
                visible: root.isRepoSearch

                Row {
                    id: repoToolbar
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.spacingM
                    height: Theme.iconSize + Theme.spacingS
                    spacing: Theme.spacingS

                    Rectangle {
                        width: repoToolbar.height
                        height: repoToolbar.height
                        radius: Theme.cornerRadiusSmall
                        color: refreshRepoArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                        Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                        DankIcon {
                            name: "refresh"
                            size: Theme.iconSizeSmall
                            color: root.isFetchingAllRepos ? Theme.surfaceVariantText : Theme.primary
                            anchors.centerIn: parent

                            RotationAnimator on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: root.isFetchingAllRepos
                            }
                        }

                        MouseArea {
                            id: refreshRepoArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: root.isFetchingAllRepos ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: {
                                if (!root.isFetchingAllRepos) {
                                    root.refreshAllRepos();
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width - repoToolbar.height - Theme.spacingS
                        text: {
                            if (root.isFetchingAllRepos)
                                return "Fetching... (" + root.repoFetchQueue.length + " remaining)";
                            if (root.totalRepoCount > 0)
                                return root.totalRepoCount + " repos from " + root.searchedHostCount + " hosts";
                            return "No repos cached";
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            // Repo search results (visible only in repo search mode)
            Item {
                width: parent.width
                visible: root.isRepoSearch
                implicitHeight: root.isRepoSearch ? (root.popoutHeight - popoutColumn.headerHeight -
                               popoutColumn.detailsHeight - 60 - Theme.spacingXL - 48 -
                               repoToolbar.height - Theme.spacingS) : 0

                ListView {
                    id: repoSearchListView
                    anchors.fill: parent
                    anchors.margins: Theme.spacingS
                    clip: true
                    spacing: Theme.spacingS
                    model: root.filteredRepos

                    delegate: StyledRect {
                        id: repoSearchDelegate
                        width: repoSearchListView.width
                        height: 52
                        radius: Theme.cornerRadius

                        property var repoData: modelData
                        property bool repoExists: root.existingRepos[modelData.repoKey] === true
                        property bool isCloning: root.activeClones[modelData.repoKey] === true
                        property bool isSelected: index === popoutColumn.selectedIndex

                        color: isSelected ? Theme.secondaryContainer :
                               repoSearchMouse.containsMouse ? Theme.surfaceContainerHighest :
                               Theme.surfaceContainerHigh

                        border.width: isSelected ? 2 : 0
                        border.color: Theme.secondary

                        Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                        Behavior on border.width { NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                name: repoSearchDelegate.repoExists ? "check_circle" : (repoSearchDelegate.isCloning ? "sync" : "folder")
                                size: Theme.iconSize
                                color: repoSearchDelegate.repoExists ? Theme.primary : (repoSearchDelegate.isCloning ? Theme.secondary : Theme.surfaceVariantText)
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                
                                RotationAnimation on rotation {
                                    running: repoSearchDelegate.isCloning
                                    from: 0
                                    to: 360
                                    duration: 1000
                                    loops: Animation.Infinite
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                width: parent.width - Theme.iconSize - cloneSearchIcon.width - Theme.spacingM * 2

                                StyledText {
                                    text: repoSearchDelegate.repoData.repoName + (repoSearchDelegate.isCloning ? " (cloning...)" : "")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideMiddle
                                    width: parent.width

                                    Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                }

                                StyledText {
                                    text: repoSearchDelegate.repoData.hostname
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                    width: parent.width

                                    Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                }
                            }

                            DankIcon {
                                id: cloneSearchIcon
                                visible: !repoSearchDelegate.repoExists && !repoSearchDelegate.isCloning
                                name: "download"
                                size: Theme.iconSize
                                color: cloneSearchMouse.containsMouse ? Theme.primary : Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on color { ColorAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing } }
                                
                                MouseArea {
                                    id: cloneSearchMouse
                                    anchors.fill: parent
                                    anchors.margins: -Theme.spacingS
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: (mouse) => {
                                        mouse.accepted = true;
                                        root.cloneGitRepo(repoSearchDelegate.repoData.hostname, repoSearchDelegate.repoData.repoName);
                                    }
                                }
                            }
                        }

                        MouseArea {
                            id: repoSearchMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: (repoSearchDelegate.repoExists || repoSearchDelegate.isCloning) ? Qt.ArrowCursor : Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton
                            
                            onEntered: {
                                popoutColumn.selectedIndex = index;
                            }
                            
                            onClicked: {
                                if (!repoSearchDelegate.repoExists && !repoSearchDelegate.isCloning) {
                                    root.cloneGitRepo(repoSearchDelegate.repoData.hostname, repoSearchDelegate.repoData.repoName);
                                }
                            }
                        }
                    }
                    
                    // Empty state for repo search
                    Item {
                        anchors.centerIn: parent
                        visible: root.filteredRepos.length === 0 && root.isRepoSearch
                        width: parent.width
                        height: emptyRepoColumn.height

                        Column {
                            id: emptyRepoColumn
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            DankIcon {
                                name: root.isFetchingAllRepos ? "sync" : (root.repoSearchQuery ? "search_off" : "folder_open")
                                size: 48
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                                
                                RotationAnimation on rotation {
                                    running: root.isFetchingAllRepos
                                    from: 0
                                    to: 360
                                    duration: 1000
                                    loops: Animation.Infinite
                                }
                            }

                            StyledText {
                                text: root.isFetchingAllRepos ? 
                                      "Fetching repositories... (" + root.repoFetchQueue.length + " hosts remaining)" :
                                      (root.repoSearchQuery ? 
                                          "No matching repositories" : 
                                          "Type to search repositories")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            StyledText {
                                visible: !root.isFetchingAllRepos
                                text: root.repoSearchQuery ? 
                                      "Searched " + root.searchedHostCount + " hosts" :
                                      "Repos will be fetched from all hosts"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 380
    popoutHeight: 700

    Component.onCompleted: {
        // hostsReader is started by refreshTimer (triggeredOnStart: true)
        loadReposCache();
    }
}
