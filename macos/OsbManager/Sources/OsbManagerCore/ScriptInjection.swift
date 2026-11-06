import Foundation

public enum ScriptInjection {
    private struct Settings: Encodable {
        let name: String
        let namespace: String
        let version: String
        let runAt: String
        let noFrames: Bool
        let include: [String]
        let exclude: [String]
    }

    public static func build(meta: UserScriptMeta, source: String) throws -> String {
        let settings = try JsonFile.string(Settings(
            name: meta.name,
            namespace: meta.namespace,
            version: meta.version,
            runAt: meta.runAt,
            noFrames: meta.noFrames,
            include: try meta.matches.map(UrlPattern.fromMatch) + meta.includes.map(UrlPattern.fromGlob),
            exclude: meta.excludes.map(UrlPattern.fromGlob)
        ))
        return "(() => {\nconst meta = \(settings);\n\(prelude)const run = () => {\n\(source)\n};\n\(launcher)})();\n"
    }

    private static let prelude = #"""
    if (meta.noFrames && window.top !== window) return;
    const matches = list => list.some(pattern => new RegExp(pattern).test(location.href));
    if (!matches(meta.include) || matches(meta.exclude)) return;
    const unsafeWindow = window;
    const GM_info = Object.freeze({ scriptHandler: 'OSB Manager', version: '1.0', script: Object.freeze({ name: meta.name, namespace: meta.namespace, version: meta.version }) });
    const storeKey = key => 'sroMultiAcc.gm:' + meta.namespace + ':' + meta.name + ':' + key;
    const GM_addStyle = css => { const style = document.createElement('style'); style.textContent = String(css); const attach = () => { (document.head || document.documentElement).appendChild(style); }; if (document.documentElement) attach(); else new MutationObserver((records, observer) => { if (document.documentElement) { observer.disconnect(); attach(); } }).observe(document, { childList: true }); return style; };
    const GM_getValue = (key, fallback) => { try { const value = localStorage.getItem(storeKey(key)); return value === null ? fallback : JSON.parse(value); } catch { return fallback; } };
    const GM_setValue = (key, value) => { try { localStorage.setItem(storeKey(key), JSON.stringify(value)); } catch {} };
    const GM_deleteValue = key => { try { localStorage.removeItem(storeKey(key)); } catch {} };
    const GM_listValues = () => { const prefix = storeKey(''); const keys = []; for (let i = 0; i < localStorage.length; i++) { const key = localStorage.key(i); if (key && key.startsWith(prefix)) keys.push(key.slice(prefix.length)); } return keys; };
    const GM = Object.freeze({ info: GM_info, addStyle: async css => GM_addStyle(css), getValue: async (key, fallback) => GM_getValue(key, fallback), setValue: async (key, value) => GM_setValue(key, value), deleteValue: async key => GM_deleteValue(key), listValues: async () => GM_listValues() });

    """#

    private static let launcher = #"""
    const start = () => { try { run(); } catch (error) { console.error('[' + meta.name + ']', error); } };
    if (meta.runAt === 'document-start') start();
    else if (meta.runAt === 'document-end' || meta.runAt === 'document-body') {
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true }); else start();
    } else if (document.readyState === 'complete') setTimeout(start, 0);
    else window.addEventListener('load', start, { once: true });

    """#
}
