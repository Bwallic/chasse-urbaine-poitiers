(() => {
  if (!window.supabase?.createClient) return;

  const previousCreateClient = window.supabase.createClient.bind(window.supabase);

  window.supabase.createClient = function autoReconnectCreateClient(...args) {
    const client = previousCreateClient(...args);
    const previousRpc = client.rpc.bind(client);
    let resumedParticipant = null;
    let resumeClaimPending = false;

    client.rpc = function autoReconnectRpc(fn, params = {}, options) {
      if (fn === "claim_participant" && resumeClaimPending && resumedParticipant) {
        resumeClaimPending = false;
        const participant = resumedParticipant;
        resumedParticipant = null;
        return Promise.resolve({ data: participant, error: null });
      }
      return previousRpc(fn, params, options);
    };

    async function tryAutoReconnect() {
      try {
        for (let attempt = 0; attempt < 12; attempt += 1) {
          const { data: sessionData } = await client.auth.getSession();
          if (sessionData?.session) break;
          await new Promise((resolve) => setTimeout(resolve, 100));
        }

        const { data, error } = await previousRpc("resume_my_participant");
        if (error || !data) return;

        const participant = Array.isArray(data) ? data[0] : data;
        if (!participant?.id || !participant?.role) return;

        const roleButton = document.querySelector(`.role-card[data-role="${participant.role}"]`);
        const pseudoInput = document.getElementById("demoPseudo");
        const codeInput = document.getElementById("accessCode");
        const joinButton = document.getElementById("joinButton");
        if (!roleButton || !pseudoInput || !codeInput || !joinButton) return;

        resumedParticipant = participant;
        resumeClaimPending = true;

        roleButton.click();
        pseudoInput.value = participant.pseudo || "Joueur";
        codeInput.value = "SESSION";
        joinButton.click();

        const badge = document.getElementById("connectionBadge");
        if (badge) badge.textContent = "Reconnecté";
      } catch (_) {
        // En cas d'échec, on laisse simplement l'écran de connexion normal.
      }
    }

    setTimeout(tryAutoReconnect, 250);
    return client;
  };
})();
