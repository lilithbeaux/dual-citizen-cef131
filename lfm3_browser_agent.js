/**
 * LFM3 Browser Agent — CEF Content Script
 * 
 * Injected into every page via CEF scheme handler at document_start.
 * Captures frames at 2fps, sends to inference service via HTTP,
 * executes returned actions via injected Godhand API.
 * 
 * Architecture:
 *   1. Frame capture via requestVideoFrameCallback or canvas drawWindow
 *   2. Buffer 2 frames + goal → POST to inference service
 *   3. Parse action from LFM3 response
 *   4. Execute via window.godhand API (injected by CEF)
 *   5. Loop until goal complete or stop requested
 */

(function () {
    'use strict';

    const AGENT_ID = 'lfm3_agent_' + Math.random().toString(36).slice(2, 10);
    const INFERENCE_ENDPOINT = 'http://localhost:8774/v1/chat/completions';
    const DEFAULT_FPS = 2;
    const FRAME_BUFFER_SIZE = 2;
    const CAPTURE_INTERVAL_MS = 1000 / DEFAULT_FPS;

    // State
    let frameInterval = null;
    let frameBuffer = [];
    let currentGoal = null;
    let isRunning = false;
    let captureMethod = null; // 'requestVideoFrameCallback' | 'canvas'
    let videoTrack = null;
    let canvas = null;
    let ctx = null;

    // --- Utility Functions ---

    function log(...args) {
        console.log('[LFM3-Agent]', ...args);
    }

    function emit(event, data) {
        try {
            window.parent.postMessage({
                type: 'event',
                event,
                data,
                agentId: AGENT_ID,
                source: 'lfm3_agent'
            }, '*');
        } catch (e) { /* ignore */ }
    }

    function sendResponse(id, result, error) {
        try {
            window.parent.postMessage({
                type: 'response',
                id,
                result,
                error: error?.message,
                agentId: AGENT_ID,
                source: 'lfm3_agent'
            }, '*');
        } catch (e) { /* ignore */ }
    }

    // --- Frame Capture Methods ---

    async function initCanvasCapture() {
        canvas = document.createElement('canvas');
        canvas.width = window.innerWidth;
        canvas.height = window.innerHeight;
        ctx = canvas.getContext('2d', { alpha: false });
        
        // Resize handler
        window.addEventListener('resize', () => {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
        });
        
        captureMethod = 'canvas';
        log('Canvas capture initialized');
    }

    async function initVideoCapture() {
        try {
            // requestVideoFrameCallback is Chrome 99+
            if ('requestVideoFrameCallback' in HTMLVideoElement.prototype) {
                // Create a video element that captures the tab
                // Note: This requires getDisplayMedia or similar - complex in CEF
                // Fall back to canvas for now
                log('requestVideoFrameCallback available but using canvas fallback');
            }
        } catch (e) {
            log('Video capture not available:', e.message);
        }
        await initCanvasCapture();
    }

    async function captureFrame() {
        if (!ctx || !canvas) return null;

        try {
            // Use drawWindow (Firefox/CEF specific) or drawImage fallback
            if (typeof ctx.drawWindow === 'function') {
                ctx.drawWindow(window, 0, 0, canvas.width, canvas.height, 'rgb');
            } else {
                // Fallback: would need to capture via other means
                // For CEF, drawWindow should be available
                ctx.drawImage(document.body, 0, 0, canvas.width, canvas.height);
            }

            const base64 = canvas.toDataURL('image/png').split(',')[1];
            
            const frame = {
                base64,
                timestamp: Date.now(),
                url: window.location.href,
                domHash: hashDOM(document.documentElement.outerHTML),
                width: canvas.width,
                height: canvas.height
            };

            return frame;
        } catch (e) {
            log('Frame capture error:', e.message);
            return null;
        }
    }

    function hashDOM(html) {
        let hash = 0;
        for (let i = 0; i < html.length; i++) {
            hash = ((hash << 5) - hash) + html.charCodeAt(i);
            hash |= 0;
        }
        return hash.toString(16);
    }

    // --- Inference Communication ---

    async function requestInference(frames, goal) {
        const messages = [{
            role: 'user',
            content: [
                { type: 'text', text: `Goal: ${goal}\n\nAnalyze these video frames and determine the next action to accomplish the goal. Return a JSON action object with: type (click|type|scroll|wait|done), selector (CSS), text (for type), x/y (for scroll), reasoning.` }
            ]
        }];

        for (const frame of frames) {
            messages[0].content.push({
                type: 'image_url',
                image_url: { url: `data:image/png;base64,${frame.base64}` }
            });
        }

        const payload = {
            model: 'LiquidAI/LFM3-VL-2B',
            messages,
            temperature: 0.1,
            max_tokens: 512,
            top_k: 50,
            repetition_penalty: 1.1
        };

        log('Requesting inference:', frames.length, 'frames, goal:', goal.slice(0, 50));

        try {
            const response = await fetch(INFERENCE_ENDPOINT, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`Inference service ${response.status}: ${errorText}`);
            }

            const result = await response.json();
            const responseText = result.choices[0].message.content;
            
            log('Inference response:', responseText.slice(0, 200));
            
            return parseActionResponse(responseText);
        } catch (e) {
            log('Inference error:', e.message);
            emit('inference_error', { error: e.message });
            return { type: 'error', error: e.message };
        }
    }

    function parseActionResponse(responseText) {
        // Try to extract JSON
        try {
            const start = responseText.indexOf('{');
            const end = responseText.lastIndexOf('}') + 1;
            if (start >= 0 && end > start) {
                const action = JSON.parse(responseText.slice(start, end));
                if (action.type || action.action) {
                    return action.type ? action : { type: action.action, ...action };
                }
            }
        } catch (e) {
            // Fall through to heuristic parsing
        }

        // Heuristic parsing
        const lower = responseText.toLowerCase();
        if (lower.includes('click')) {
            // Try to extract selector
            const selectorMatch = responseText.match(/['"`]([^'"`]+)['"`]/);
            return {
                type: 'click',
                selector: selectorMatch ? selectorMatch[1] : 'button, a, [role="button"]',
                reasoning: responseText
            };
        }
        if (lower.includes('type') || lower.includes('fill') || lower.includes('input')) {
            const textMatch = responseText.match(/['"`]([^'"`]+)['"`]/);
            return {
                type: 'type',
                selector: 'input, textarea, [contenteditable="true"]',
                text: textMatch ? textMatch[1] : '',
                reasoning: responseText
            };
        }
        if (lower.includes('scroll')) {
            return { type: 'scroll', x: 0, y: 500, reasoning: responseText };
        }
        if (lower.includes('done') || lower.includes('complete') || lower.includes('finish')) {
            return { type: 'done', reasoning: responseText };
        }

        return { type: 'unknown', reasoning: responseText };
    }

    // --- Action Execution via Godhand API ---

    async function executeAction(action) {
        if (!window.godhand) {
            log('Godhand API not available, waiting...');
            // Wait for godhand to be injected
            await waitForGodhand(5000);
        }

        if (!window.godhand) {
            emit('action_error', { action, error: 'Godhand API not available' });
            return { success: false, error: 'Godhand API not available' };
        }

        try {
            let result;
            switch (action.type) {
                case 'click':
                    result = await window.godhand.click(action.selector);
                    break;
                case 'type':
                    result = await window.godhand.type(action.selector, action.text || '');
                    break;
                case 'scroll':
                    result = await window.godhand.scroll(action.selector || 'body', action.x || 0, action.y || 0);
                    break;
                case 'wait':
                    result = await window.godhand.waitForSelector(action.selector, action.timeout || 5000);
                    break;
                case 'screenshot':
                    result = await window.godhand.screenshot();
                    break;
                case 'done':
                    result = { success: true, done: true };
                    break;
                default:
                    result = { success: false, error: `Unknown action type: ${action.type}` };
            }

            emit('action_executed', { action, result });
            return result;
        } catch (e) {
            log('Action execution error:', e.message);
            emit('action_error', { action, error: e.message });
            return { success: false, error: e.message };
        }
    }

    function waitForGodhand(timeout = 5000) {
        return new Promise((resolve) => {
            if (window.godhand) return resolve();
            const start = Date.now();
            const check = () => {
                if (window.godhand) return resolve();
                if (Date.now() - start > timeout) return resolve(); // Give up
                setTimeout(check, 100);
            };
            check();
        });
    }

    // --- Main Loop ---

    async function captureAndInfer() {
        if (!isRunning) return;

        const frame = await captureFrame();
        if (!frame) {
            log('Frame capture failed');
            return;
        }

        frameBuffer.push(frame);
        if (frameBuffer.length > FRAME_BUFFER_SIZE) {
            frameBuffer.shift();
        }

        log(`Frame captured (${frameBuffer.length}/${FRAME_BUFFER_SIZE})`);

        if (frameBuffer.length >= FRAME_BUFFER_SIZE && currentGoal) {
            const action = await requestInference([...frameBuffer], currentGoal);
            
            if (action.type === 'done') {
                log('Goal complete');
                emit('goal_complete', { goal: currentGoal });
                stop();
                return;
            }

            if (action.type !== 'error' && action.type !== 'unknown') {
                const result = await executeAction(action);
                
                // Wait a bit for action to take effect before next capture
                await new Promise(r => setTimeout(r, 1000));
            }
        }
    }

    async function start(goal) {
        if (isRunning) {
            log('Already running, stopping first');
            stop();
        }

        currentGoal = goal;
        isRunning = true;
        frameBuffer = [];

        await initVideoCapture();
        
        log('Starting LFM3 agent with goal:', goal);
        emit('started', { goal });

        // Initial capture
        await captureAndInfer();

        // Start interval
        frameInterval = setInterval(captureAndInfer, CAPTURE_INTERVAL_MS);
    }

    function stop() {
        isRunning = false;
        currentGoal = null;
        
        if (frameInterval) {
            clearInterval(frameInterval);
            frameInterval = null;
        }
        
        frameBuffer = [];
        
        if (videoTrack) {
            videoTrack.getTracks().forEach(t => t.stop());
            videoTrack = null;
        }

        log('Stopped');
        emit('stopped', {});
    }

    function getStatus() {
        return {
            running: isRunning,
            goal: currentGoal,
            bufferSize: frameBuffer.length,
            captureMethod,
            agentId: AGENT_ID
        };
    }

    // --- Message Handler ---

    async function handleMessage(event) {
        if (event.source !== window.parent) return;
        const msg = event.data;
        if (!msg || msg.target !== AGENT_ID && msg.target !== 'lfm3_agent') return;

        const { id, command, params } = msg;

        try {
            let result;
            switch (command) {
                case 'start':
                    await start(params.goal);
                    result = { success: true };
                    break;
                case 'stop':
                    stop();
                    result = { success: true };
                    break;
                case 'status':
                    result = getStatus();
                    break;
                case 'setGoal':
                    currentGoal = params.goal;
                    result = { success: true, goal: currentGoal };
                    break;
                case 'captureFrame':
                    const frame = await captureFrame();
                    result = frame ? { success: true, frame } : { success: false };
                    break;
                case 'executeAction':
                    result = await executeAction(params.action);
                    break;
                default:
                    throw new Error(`Unknown command: ${command}`);
            }
            sendResponse(id, result);
        } catch (err) {
            sendResponse(id, null, err);
        }
    }

    // --- Initialization ---

    function init() {
        window.addEventListener('message', handleMessage);
        
        // Expose minimal API for debugging
        window.lfm3Agent = {
            start,
            stop,
            getStatus,
            captureFrame,
            executeAction,
            agentId: AGENT_ID
        };

        // Signal ready
        try {
            window.parent.postMessage({
                type: 'ready',
                agentId: AGENT_ID,
                source: 'lfm3_agent',
                url: window.location.href
            }, '*');
        } catch (e) {}

        log('LFM3 Browser Agent initialized');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();