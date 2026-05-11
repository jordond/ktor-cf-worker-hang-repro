// Polyfill process.hrtime so Kotlin/JS TimeSource.Monotonic works in workerd.
// Kotlin's stdlib checks process.versions.node and calls process.hrtime when
// truthy; the polyfill in workerd has process but not hrtime.
if (typeof process !== "undefined" && !process.hrtime) {
    process.hrtime = function (prev) {
        const now = performance.now();
        const sec = Math.floor(now / 1000);
        const nano = Math.floor((now % 1000) * 1e6);
        if (prev) {
            let ds = sec - prev[0];
            let dn = nano - prev[1];
            if (dn < 0) { ds--; dn += 1e9; }
            return [ds, dn];
        }
        return [sec, nano];
    };
}

const lib = await import("./build/compileSync/js/main/productionExecutable/kotlin/ktor-cf-worker-hang-repro.mjs");

export default {
    async fetch(request, env, ctx) {
        return lib.fetch(request, env, ctx);
    },
};
