const lib = await import("./build/compileSync/js/main/productionExecutable/kotlin/ktor-cf-worker-hang-repro.mjs");

export default {
    async fetch(request, env, ctx) {
        return lib.fetch(request, env, ctx);
    },
};
