/* SleepFix UI. ES5 syntax for the webOS TV browser; no network dependencies. */
(function () {
    'use strict';

    var APP_VERSION = '0.1.1';
    var CONTROL = '/bin/sh /media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix/bin/sleepfixctl.sh ';
    var COMMANDS = {
        status: CONTROL + 'status-json',
        start: CONTROL + 'start --timers-off',
        stop: CONTROL + 'stop --timers-off',
        bootOn: CONTROL + 'boot-on',
        bootOff: CONTROL + 'boot-off'
    };
    var EXEC_URI = 'luna://org.webosbrew.hbchannel.service/exec';
    var preview = /(?:^|[?&])preview=1(?:&|$)/.test(window.location.search);
    var liveRequests = {};
    var nextRequest = 0;
    var state = null;
    var statusKnown = false;
    var busy = false;
    var busyAction = '';
    var uncertain = false;
    var statusPending = false;
    var pendingAction = null;
    var returnFocus = null;
    var noticeText = '';
    var noticeError = false;
    var ids = [
        'preview-label', 'status-title', 'status-description', 'status-badge',
        'status-badge-text', 'fix-toggle', 'boot-toggle', 'start-button',
        'stop-button', 'root-detail', 'support-detail', 'daemon-detail',
        'boot-note', 'refresh-button', 'notice', 'confirm-overlay',
        'confirm-title', 'confirm-extra', 'confirm-button', 'cancel-button'
    ];
    var el = {};
    var i;
    for (i = 0; i < ids.length; i += 1) { el[ids[i]] = document.getElementById(ids[i]); }

    var previewState = {
        returnValue: true,
        supported: true,
        root: true,
        running: true,
        bootEnabled: true,
        bootHookValid: true,
        operationInProgress: false,
        canStart: true,
        canStop: true,
        serviceState: 'active/running',
        pid: 6520,
        systemSha256: '23bb2fe19594d1b42d4dfdbcf3d40b675f225ac15990b9d2a5cb2c0b571cd40f',
        runningSha256: '23bb2fe19594d1b42d4dfdbcf3d40b675f225ac15990b9d2a5cb2c0b571cd40f',
        overlay: 'ours',
        version: APP_VERSION,
        legacyHook: false,
        message: ''
    };

    function text(node, value) { if (node.textContent !== value) { node.textContent = value; } }

    function setNotice(message, isError) {
        noticeText = message || '';
        noticeError = !!isError;
        el.notice.hidden = !noticeText;
        el.notice.className = 'notice' + (noticeError ? ' error' : '');
        text(el.notice, noticeText);
    }

    function render() {
        var locked = busy || uncertain || (statusKnown && state.operationInProgress);
        var root = statusKnown && state.root === true;
        var running = statusKnown && state.running === true;
        var supported = statusKnown && state.supported === true;
        var owns = statusKnown && state.overlay === 'ours';
        var canStart = root && supported && (!state || state.canStart !== false);
        var canStop = root && (typeof state.canStop === 'boolean' ? state.canStop : (running || owns));
        var title;
        var description;
        var badge;
        var badgeClass;

        if (busy) {
            title = busyAction === 'stop' ? 'Restoring normal timer behavior…' :
                (busyAction === 'start' ? 'Starting SleepFix…' : 'Updating startup setting…');
            description = 'Keep this app open while the operation finishes.';
            badge = 'Working'; badgeClass = 'busy';
        } else if (uncertain) {
            title = 'Checking the operation';
            description = 'The command reply was delayed. Refreshing the actual TV state.';
            badge = 'Checking'; badgeClass = 'busy';
        } else if (!statusKnown) {
            title = 'Status unavailable';
            description = 'Refresh to check the TV. No running state is assumed.';
            badge = 'Unknown'; badgeClass = 'unknown';
        } else if (!root) {
            title = 'Root access is needed';
            description = 'A rooted TV and Homebrew Channel are required to use SleepFix.';
            badge = 'Unavailable'; badgeClass = 'error';
        } else if (state.operationInProgress) {
            title = 'A SleepFix operation is in progress';
            description = 'Status will refresh automatically when it finishes.';
            badge = 'Working'; badgeClass = 'busy';
        } else if (running) {
            title = 'SleepFix is running';
            description = 'The sleep timer warning can appear without waking the screen.';
            badge = 'Running'; badgeClass = 'running';
        } else if (owns || canStop) {
            title = 'SleepFix needs attention';
            description = 'The fix is only partly applied. Use Stop service to restore normal behavior.';
            badge = 'Check service'; badgeClass = 'error';
        } else if (!supported) {
            title = 'This firmware is not supported';
            description = 'The TV’s executable does not match a verified SleepFix version.';
            badge = 'Unsupported'; badgeClass = 'error';
        } else {
            title = 'SleepFix is stopped';
            description = 'LG’s normal sleep timer behavior is active.';
            badge = 'Stopped'; badgeClass = 'stopped';
        }
        text(el['status-title'], title);
        text(el['status-description'], description);
        text(el['status-badge-text'], badge);
        el['status-badge'].className = 'status-badge ' + badgeClass;
        el['fix-toggle'].setAttribute('aria-checked', running ? 'true' : 'false');
        el['fix-toggle'].disabled = locked || (running ? !canStop : !canStart);
        el['start-button'].disabled = locked || !canStart;
        el['stop-button'].disabled = locked || !canStop;
        el['boot-toggle'].setAttribute('aria-checked', statusKnown && state.bootEnabled ? 'true' : 'false');
        el['boot-toggle'].disabled = locked || !root || (!supported && !(statusKnown && state.bootEnabled));

        text(el['root-detail'], !statusKnown ? 'Unknown' : (root ? 'Ready' : 'Root unavailable'));
        text(el['support-detail'], !statusKnown || !root ? 'Unknown' : (supported ? 'Verified executable' : 'Unsupported executable'));
        text(el['daemon-detail'], !statusKnown ? 'Unknown' :
            ((state.serviceState === 'active/running') ? 'Running' + (state.pid ? ' · PID ' + state.pid : '') : (state.serviceState || 'Unknown')));

        if (statusKnown && state.bootEnabled && !state.bootHookValid) {
            text(el['boot-note'], 'Startup is enabled, but its hook needs repair. Toggle it off, then on.');
        } else {
            text(el['boot-note'], 'Applies on the next full boot. Stopping it now keeps this setting.');
        }

        if (statusKnown && state.legacyHook && !noticeError && !busy && !uncertain) {
            setNotice('Existing SSH setup detected. Start service once to let this app manage startup.', false);
        } else if (statusKnown && state.message && !noticeError && !busy && !uncertain) {
            setNotice(state.message, false);
        }
        if (document.activeElement && document.activeElement.disabled && !pendingAction) {
            el['refresh-button'].focus();
        }
    }

    function errorMessage(result) {
        var message = result.stderrString || result.errorText || 'The command could not be completed.';
        message = String(message).replace(/^\s+|\s+$/g, '');
        return message.length > 650 ? message.slice(0, 650) + '…' : message;
    }

    function previewExec(action, done) {
        window.setTimeout(function () {
            if (action === 'start') {
                previewState.running = true;
                previewState.overlay = 'ours';
                previewState.canStop = true;
                previewState.legacyHook = false;
            } else if (action === 'stop') {
                previewState.running = false;
                previewState.overlay = 'not_ours_or_absent';
                previewState.canStop = false;
            } else if (action === 'bootOn') { previewState.bootEnabled = true; }
            else if (action === 'bootOff') { previewState.bootEnabled = false; }
            done(null, {returnValue: true, stdoutString: action === 'status' ? JSON.stringify(previewState) : 'Preview operation completed.'});
        }, action === 'status' ? 80 : 450);
    }

    function exec(action, done) {
        var bridge;
        var requestId;
        var timeout;
        var replied = false;
        var callAttempted = false;
        if (!Object.prototype.hasOwnProperty.call(COMMANDS, action)) {
            done({message: 'Unknown SleepFix action.'}); return;
        }
        if (preview) { previewExec(action, done); return; }
        if (typeof window.PalmServiceBridge !== 'function') {
            done({message: 'Open SleepFix on your LG TV. The webOS service bridge is unavailable here.'}); return;
        }
        requestId = String(++nextRequest);
        try {
            bridge = new window.PalmServiceBridge();
            liveRequests[requestId] = bridge;
            timeout = window.setTimeout(function () {
                if (replied) { return; }
                replied = true;
                done({message: 'No command reply received. The operation may still be running; use Refresh status.', uncertain: action !== 'status'});
                if (action === 'status') {
                    delete liveRequests[requestId];
                    if (bridge && typeof bridge.cancel === 'function') {
                        try { bridge.cancel(); } catch (cancelError) { /* Read-only request timed out. */ }
                    }
                }
                // Keep the bridge alive for a late completion. A UI timeout must
                // not cancel or claim to roll back a root-side operation.
            }, action === 'status' ? 15000 : 120000);
            bridge.onservicecallback = function (raw) {
                var result;
                var late = replied;
                window.clearTimeout(timeout);
                try { result = typeof raw === 'string' ? JSON.parse(raw) : raw; }
                catch (parseError) { result = {returnValue: false, errorText: 'Homebrew Channel returned an unreadable response.'}; }
                delete liveRequests[requestId];
                if (bridge && typeof bridge.cancel === 'function') {
                    try { bridge.cancel(); } catch (cancelError) { /* Response already complete. */ }
                }
                if (late) {
                    if (action !== 'status') { uncertain = false; busy = false; refresh(true); }
                    return;
                }
                replied = true;
                if (!result || result.returnValue !== true) {
                    done({message: errorMessage(result || {})}, result);
                } else { done(null, result); }
            };
            callAttempted = true;
            bridge.call(EXEC_URI, JSON.stringify({command: COMMANDS[action]}));
        } catch (bridgeError) {
            window.clearTimeout(timeout);
            if (!callAttempted || action === 'status') { delete liveRequests[requestId]; }
            if (!replied) {
                replied = true;
                done({message: 'Could not confirm the Homebrew Channel reply: ' + bridgeError.message,
                    uncertain: callAttempted && action !== 'status'});
            }
        }
    }

    function refresh(userRequested) {
        if (statusPending) { return; }
        statusPending = true;
        exec('status', function (error, result) {
            var parsed;
            statusPending = false;
            if (error && !(result && result.stdoutString)) {
                statusKnown = false;
                setNotice(error.message, true);
                render(); return;
            }
            try { parsed = JSON.parse(result.stdoutString); }
            catch (parseError) {
                statusKnown = false;
                setNotice('The status response could not be read. Refresh or check the controller over SSH.', true);
                render(); return;
            }
            if (parsed && parsed.root === false) {
                state = {returnValue: false, root: false, supported: false, running: false,
                    bootEnabled: false, bootHookValid: false, operationInProgress: false,
                    canStart: false, canStop: false, overlay: 'unknown', serviceState: 'Unknown'};
                statusKnown = true;
                setNotice(parsed.errorText || parsed.message || 'The controller could not obtain root access.', true);
                render(); return;
            }
            if (error) {
                statusKnown = false;
                setNotice(error.message, true);
                render(); return;
            }
            if (!parsed || parsed.returnValue !== true || typeof parsed.running !== 'boolean' || typeof parsed.root !== 'boolean') {
                statusKnown = false;
                setNotice(parsed && parsed.message ? parsed.message : 'The TV returned an incomplete status response.', true);
                render(); return;
            }
            state = parsed;
            statusKnown = true;
            if (uncertain && parsed.operationInProgress === false) {
                uncertain = false;
                setNotice('Status refreshed. The current state shown above comes from the TV.', false);
            } else if (userRequested && !busy && !uncertain) { setNotice('', false); }
            render();
        });
    }

    function runAction(action) {
        if (busy || uncertain || !statusKnown || state.operationInProgress) { return; }
        busy = true;
        busyAction = action;
        setNotice('', false);
        render();
        exec(action, function (error) {
            busy = false;
            if (error) {
                uncertain = !!error.uncertain;
                setNotice(error.message, true);
            } else {
                setNotice(action === 'bootOn' ? 'Launch at boot is enabled.' :
                    (action === 'bootOff' ? 'Launch at boot is disabled.' :
                    (action === 'stop' ? 'Normal timer behavior restored. The startup setting is unchanged.' : 'SleepFix is ready.')), false);
            }
            render();
            refresh(false);
        });
    }

    function closeConfirmation() {
        pendingAction = null;
        el['confirm-overlay'].hidden = true;
        if (returnFocus && !returnFocus.disabled) { returnFocus.focus(); }
        else { el['refresh-button'].focus(); }
    }

    function requestAction(action) {
        if (busy || uncertain || !statusKnown || state.operationInProgress) { return; }
        if (action === 'start' && state.running === true) { runAction(action); return; }
        pendingAction = action;
        returnFocus = document.activeElement;
        text(el['confirm-title'], action === 'stop' ? 'Stop SleepFix?' : 'Start SleepFix?');
        text(el['confirm-extra'], action === 'stop' ?
            'This restores LG’s normal timer behavior and keeps your launch-at-boot setting.' :
            'The fix will be applied only if your TV’s executable matches a verified version.');
        el['confirm-overlay'].hidden = false;
        el['cancel-button'].focus();
    }

    function navigable() {
        var scope = pendingAction ? el['confirm-overlay'] : document;
        var nodes = scope.querySelectorAll('[data-nav]');
        var list = [];
        var j;
        for (j = 0; j < nodes.length; j += 1) {
            if (!nodes[j].disabled && nodes[j].offsetParent !== null) { list.push(nodes[j]); }
        }
        return list;
    }

    function moveFocus(direction) {
        var list = navigable();
        var active = document.activeElement;
        var origin;
        var best = null;
        var bestScore = Infinity;
        var j;
        if (!list.length) { return; }
        if (list.indexOf(active) < 0) { list[0].focus(); return; }
        origin = active.getBoundingClientRect();
        for (j = 0; j < list.length; j += 1) {
            var rect;
            var dx;
            var dy;
            var along;
            var across;
            var score;
            if (list[j] === active) { continue; }
            rect = list[j].getBoundingClientRect();
            dx = (rect.left + rect.right - origin.left - origin.right) / 2;
            dy = (rect.top + rect.bottom - origin.top - origin.bottom) / 2;
            along = direction === 37 ? -dx : (direction === 39 ? dx : (direction === 38 ? -dy : dy));
            across = direction === 37 || direction === 39 ? Math.abs(dy) : Math.abs(dx);
            if (along <= 5) { continue; }
            score = along + across * 2.5;
            if (score < bestScore) { bestScore = score; best = list[j]; }
        }
        if (best) { best.focus(); }
    }

    el['start-button'].onclick = function () { requestAction('start'); };
    el['stop-button'].onclick = function () { requestAction('stop'); };
    el['fix-toggle'].onclick = function () { requestAction(state.running ? 'stop' : 'start'); };
    el['boot-toggle'].onclick = function () { runAction(state.bootEnabled ? 'bootOff' : 'bootOn'); };
    el['refresh-button'].onclick = function () { refresh(true); };
    el['cancel-button'].onclick = closeConfirmation;
    el['confirm-button'].onclick = function () {
        var action = pendingAction;
        closeConfirmation();
        if (action) { runAction(action); }
    };
    document.addEventListener('keydown', function (event) {
        var key = event.keyCode || event.which;
        if (key >= 37 && key <= 40) { event.preventDefault(); moveFocus(key); }
        else if (key === 13 && document.activeElement && document.activeElement.tagName === 'BUTTON') {
            event.preventDefault(); document.activeElement.click();
        } else if (key === 461 || key === 27) {
            if (pendingAction) { event.preventDefault(); closeConfirmation(); }
            else if (key === 461 && !preview) { event.preventDefault(); window.close(); }
        }
    });
    document.addEventListener('visibilitychange', function () {
        if (!document.hidden) { refresh(false); }
    });
    el['preview-label'].hidden = !preview;
    el['refresh-button'].focus();
    refresh(false);
    window.setInterval(function () {
        if (!document.hidden) { refresh(false); }
    }, 3000);
}());
