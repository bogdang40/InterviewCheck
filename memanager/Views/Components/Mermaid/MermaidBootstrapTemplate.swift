import Foundation

/// Builds the HTML bootstrap document loaded into the Mermaid WKWebView.
enum MermaidBootstrapTemplate {
    static func mermaidBootstrapHTML(minHeight: CGFloat) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <script src="mermaid.min.js"></script>
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                html, body {
                    background: transparent;
                    color: #8e8e93;
                    font: 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    overflow: auto;
                    min-height: \(Int(minHeight.rounded()))px;
                }
                #frame {
                    min-height: \(Int(minHeight.rounded()))px;
                    width: fit-content;
                    min-width: 100%;
                    position: relative;
                }
                #active-layer {
                    min-height: \(Int(minHeight.rounded()))px;
                }
                #fallback-layer {
                    min-height: \(Int(minHeight.rounded()))px;
                }
                .placeholder {
                    min-height: \(Int(minHeight.rounded()))px;
                    color: #8e8e93;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    text-align: center;
                    padding: 12px;
                }
                .mermaid {
                    display: block;
                    min-height: 100px;
                    padding: 16px;
                    width: fit-content;
                }
                .mermaid-stage {
                    display: inline-block;
                    transform-origin: top left;
                    width: fit-content;
                }
                .mermaid svg {
                    max-width: none !important;
                    width: auto !important;
                    height: auto;
                }
            </style>
        </head>
        <body>
            <div id="frame">
                <div id="active-layer">
                    <div class="placeholder">Rendering diagram...</div>
                </div>
                <div id="fallback-layer"></div>
            </div>
            <script>
                const memanagerBridge = (() => {
                    const state = {
                        lastGoodMarkup: '',
                        lastGoodHeight: \(Int(minHeight.rounded())),
                        renderSequence: 0,
                        mermaidInitializedTheme: null,
                        lastRequestedMinHeight: \(Int(minHeight.rounded()))
                    };

                    function postStatus(name, details, contextID) {
                        try {
                            window.webkit.messageHandlers.mermaidStatus.postMessage({
                                name: name,
                                details: details || '',
                                contextID: contextID || null
                            });
                        } catch (_) {}
                    }

                    function postHeight(height, contextID) {
                        try {
                            window.webkit.messageHandlers.mermaidHeight.postMessage({
                                height: height,
                                contextID: contextID || null
                            });
                        } catch (_) {}
                    }

                    function activeLayer() {
                        return document.getElementById('active-layer');
                    }

                    function fallbackLayer() {
                        return document.getElementById('fallback-layer');
                    }

                    function setColors(backgroundColor, textColor) {
                        const bg = backgroundColor || 'transparent';
                        const text = textColor || '#333333';
                        document.body.style.backgroundColor = bg;
                        document.body.style.color = text;
                    }

                    function applyMarkup(markup) {
                        const active = activeLayer();
                        const fallback = fallbackLayer();
                        if (!active || !fallback) { return; }
                        active.innerHTML = markup;
                        fallback.innerHTML = '';
                    }

                    function ensurePlaceholder() {
                        const active = activeLayer();
                        if (!active) { return; }
                        if (active.querySelector('svg')) { return; }
                        active.innerHTML = '<div class="placeholder">Rendering diagram...</div>';
                    }

                    function measureAndPostHeight(contextID) {
                        requestAnimationFrame(() => {
                            const active = activeLayer();
                            const stageElement = active ? active.querySelector('.mermaid-stage') : null;
                            const svgElement = active ? active.querySelector('svg') : null;
                            if (!svgElement) {
                                postStatus('render_height_missing_svg', 'missing_svg', contextID);
                                return;
                            }
                            svgElement.style.maxWidth = 'none';
                            svgElement.style.width = 'auto';
                            const bounds = stageElement
                                ? stageElement.getBoundingClientRect()
                                : svgElement.getBoundingClientRect();
                            const paddedHeight = Math.ceil(bounds.height + 32);
                            state.lastGoodHeight = paddedHeight;
                            postHeight(paddedHeight, contextID);
                            postStatus('render_height_ack', String(paddedHeight), contextID);
                        });
                    }

                    function recoverFromGeometry(contextID, reason) {
                        const active = activeLayer();
                        if (!active) {
                            postStatus('render_geometry_refresh_missing_active', reason || 'missing_active', contextID);
                            return 'missing_active';
                        }

                        if (active.querySelector('svg')) {
                            const stageElement = active.querySelector('.mermaid-stage');
                            if (stageElement) {
                                const previousTransform = stageElement.style.transform || '';
                                stageElement.style.transform = previousTransform + ' translateZ(0)';
                                stageElement.getBoundingClientRect();
                                stageElement.style.transform = previousTransform;
                            } else {
                                active.getBoundingClientRect();
                            }
                            postStatus('render_geometry_refresh_kept_current', reason || 'kept_current', contextID);
                            measureAndPostHeight(contextID);
                            return 'kept_current';
                        }

                        if (state.lastGoodMarkup) {
                            applyMarkup(state.lastGoodMarkup);
                            postStatus('render_kept_last_good', 'geometry_recovery_last_good', contextID);
                            postHeight(Math.max(state.lastGoodHeight, state.lastRequestedMinHeight), contextID);
                            return 'restored_last_good';
                        }

                        postStatus('render_geometry_refresh_no_last_good', reason || 'no_last_good', contextID);
                        return 'no_last_good';
                    }

                    async function ensureMermaid(theme, contextID) {
                        if (!window.mermaid) {
                            postStatus('render_runtime_missing', 'window.mermaid missing', contextID);
                            throw new Error('Mermaid runtime unavailable');
                        }

                        if (state.mermaidInitializedTheme === theme) {
                            return;
                        }

                        window.mermaid.initialize({
                            startOnLoad: false,
                            theme: theme,
                            securityLevel: 'antiscript',
                            flowchart: {
                                useMaxWidth: false,
                                htmlLabels: true,
                                curve: 'basis'
                            },
                            sequence: {
                                useMaxWidth: false,
                                wrap: true
                            },
                            er: {
                                useMaxWidth: false
                            }
                        });
                        state.mermaidInitializedTheme = theme;
                        postStatus('runtime_ready', 'theme=' + theme, contextID);
                    }

                    async function renderDiagramMarkup(diagramText, renderID, zoomScale) {
                        const renderResult = await window.mermaid.render(renderID, diagramText);
                        return (
                            '<div class="mermaid">' +
                                '<div class="mermaid-stage" style="transform: scale(' + zoomScale + ');">' +
                                    renderResult.svg +
                                '</div>' +
                            '</div>'
                        );
                    }

                    async function render(payload) {
                        const contextID = (payload && payload.contextID) ? payload.contextID : '';
                        const theme = payload && payload.theme ? payload.theme : 'default';
                        const diagramText = payload && payload.diagramText ? payload.diagramText : '';
                        const retryDiagramText = payload && payload.retryDiagramText ? payload.retryDiagramText : diagramText;
                        const zoomScale = payload && payload.zoomScale ? payload.zoomScale : 1.0;
                        const minHeight = payload && payload.minHeight ? payload.minHeight : \(Int(minHeight.rounded()));
                        const sequence = ++state.renderSequence;
                        state.lastRequestedMinHeight = minHeight;

                        try {
                            setColors(payload.backgroundColor, payload.textColor);
                            postStatus('render_start', 'sequence=' + sequence, contextID);

                            await ensureMermaid(theme, contextID);
                            try {
                                const markup = await renderDiagramMarkup(diagramText, 'mermaid-primary-' + Date.now() + '-' + sequence, zoomScale);
                                if (sequence !== state.renderSequence) {
                                    postStatus('render_superseded_js', 'sequence=' + sequence, contextID);
                                    return;
                                }
                                applyMarkup(markup);
                                state.lastGoodMarkup = markup;
                                postStatus('render_primary_success', 'primary', contextID);
                                measureAndPostHeight(contextID);
                                return;
                            }
                            catch (primaryError) {
                                const primaryMessage = (primaryError && primaryError.message) ? primaryError.message : String(primaryError);
                                postStatus('render_error_primary', primaryMessage, contextID);
                            }

                            if (retryDiagramText !== diagramText) {
                                try {
                                    const retryMarkup = await renderDiagramMarkup(retryDiagramText, 'mermaid-repair-' + Date.now() + '-' + sequence, zoomScale);
                                    if (sequence !== state.renderSequence) {
                                        postStatus('render_superseded_js', 'sequence=' + sequence, contextID);
                                        return;
                                    }
                                    applyMarkup(retryMarkup);
                                    state.lastGoodMarkup = retryMarkup;
                                    postStatus('render_repair_success', 'retry', contextID);
                                    measureAndPostHeight(contextID);
                                    return;
                                } catch (retryError) {
                                    const retryMessage = (retryError && retryError.message) ? retryError.message : String(retryError);
                                    postStatus('render_error_repair', retryMessage, contextID);
                                }
                            }

                            if (state.lastGoodMarkup) {
                                applyMarkup(state.lastGoodMarkup);
                                postStatus('render_kept_last_good', 'using_previous_markup', contextID);
                                postHeight(Math.max(state.lastGoodHeight, minHeight), contextID);
                                return;
                            }

                            ensurePlaceholder();
                            postStatus('render_placeholder_retained', 'no_last_good', contextID);
                            postHeight(Math.max(state.lastGoodHeight, minHeight), contextID);
                        } catch (runtimeError) {
                            const runtimeMessage = (runtimeError && runtimeError.message) ? runtimeError.message : String(runtimeError);
                            postStatus('render_runtime_error', runtimeMessage, contextID);

                            if (state.lastGoodMarkup) {
                                applyMarkup(state.lastGoodMarkup);
                                postStatus('render_kept_last_good', 'runtime_error_last_good', contextID);
                                postHeight(Math.max(state.lastGoodHeight, minHeight), contextID);
                                return;
                            }

                            ensurePlaceholder();
                            postStatus('render_placeholder_retained', 'runtime_error_placeholder', contextID);
                            postHeight(Math.max(state.lastGoodHeight, minHeight), contextID);
                        }
                    }

                    return {
                        render: async function(payload) {
                            const resolvedPayload = (typeof payload === 'string') ? JSON.parse(payload) : payload;
                            await render(resolvedPayload || {});
                        },
                        recoverFromGeometry: function(contextID, reason) {
                            return recoverFromGeometry(contextID || null, reason || 'geometry');
                        }
                    };
                })();

                window.__memanagerBridge = memanagerBridge;
                try {
                    window.webkit.messageHandlers.mermaidStatus.postMessage({
                        name: 'bridge_ready',
                        details: 'bootstrap_complete',
                        contextID: null
                    });
                } catch (_) {}
            </script>
        </body>
        </html>
        """
    }
}

extension MermaidDiagramView.MermaidRenderPayload {
    func javascriptObjectLiteral() -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
