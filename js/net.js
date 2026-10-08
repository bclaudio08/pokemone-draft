/* Network layer for draft rooms: anonymous sign-in, database calls, live updates. */
(() => {
  "use strict";
  const cfg = window.G151_CONFIG || {};
  let client = null;
  let signingIn = null;

  async function ensureSession() {
    if (!client) {
      client = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
        auth: { persistSession: true, autoRefreshToken: true, storageKey: "g151-auth" },
      });
    }
    if (!signingIn) {
      signingIn = (async () => {
        const { data } = await client.auth.getSession();
        if (!data.session) {
          const { error } = await client.auth.signInAnonymously();
          if (error) throw new Error("Couldn't connect to draft rooms: " + error.message);
        }
      })().catch(e => { signingIn = null; throw e; });
    }
    return signingIn;
  }

  window.G151Net = window.G151_TEST_NET || {
    available: !!(cfg.supabaseUrl && cfg.supabaseKey && window.supabase),
    async rpc(name, args) {
      await ensureSession();
      const { data, error } = await client.rpc(name, args);
      if (error) throw new Error(error.message);
      return data;
    },
    // calls onChange whenever anything in the room changes; returns an unsubscribe function
    subscribe(roomId, onChange) {
      if (!client) return () => {};
      const ch = client.channel("g151-" + roomId);
      for (const table of ["g151_rooms", "g151_seats", "g151_picks"]) {
        const filter = table === "g151_rooms" ? `id=eq.${roomId}` : `room_id=eq.${roomId}`;
        ch.on("postgres_changes", { event: "*", schema: "public", table, filter }, onChange);
      }
      ch.subscribe();
      return () => client.removeChannel(ch);
    },
  };
})();
