(() => {
  const style = document.createElement("style");
  style.textContent = `
    .access-reset-block {
      margin: 14px 0;
      padding: 12px;
      border: 1px solid rgba(255,216,107,.28);
      border-radius: 10px;
      background: rgba(255,216,107,.045);
    }
    .access-reset-actions {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin-top: 10px;
    }
    .access-reset-actions button { width: 100%; }
    @media (max-width: 620px) {
      .access-reset-actions { grid-template-columns: 1fr; }
    }
  `;
  document.head.appendChild(style);

  function getClient() {
    return window.CHASSE_LIVE_CLIENT || null;
  }

  function injectAccessResetControls() {
    const panel = document.getElementById("organizerPanel");
    if (!panel || document.getElementById("resetPlayerAccessBtn")) return;

    const block = document.createElement("div");
    block.className = "access-reset-block";
    block.innerHTML = `
      <span class="eyebrow">ACCÈS / APPAREILS</span>
      <div class="big-status">Réinitialisation des codes utilisés</div>
      <p class="muted compact">Ces commandes ne changent pas les codes, les rôles, les équipes ou les pseudos. Elles libèrent seulement l'association entre un code et l'appareil qui l'a déjà utilisé.</p>
      <div class="access-reset-actions">
        <button id="resetPlayerAccessBtn" class="ghost">RESET ACCÈS JOUEURS</button>
        <button id="resetAllAccessBtn" class="ghost">RESET TOUS LES ACCÈS</button>
      </div>
      <p class="muted compact"><strong>RESET ACCÈS JOUEURS</strong> : Cibles + Chasseurs uniquement. <strong>RESET TOUS LES ACCÈS</strong> : inclut aussi les Organisateurs et te déconnectera de cet accès.</p>
    `;

    const resetPartyBtn = document.getElementById("resetPartyBtn");
    const runtimeRoot = resetPartyBtn?.closest(".runtime-controls")?.parentElement;
    if (runtimeRoot) runtimeRoot.insertAdjacentElement("afterend", block);
    else panel.appendChild(block);

    document.getElementById("resetPlayerAccessBtn").addEventListener("click", async () => {
      if (!confirm("Libérer tous les codes déjà utilisés par les Cibles et les Chasseurs ? Les codes resteront identiques et pourront être utilisés sur de nouveaux appareils.")) return;
      const client = getClient();
      if (!client) return alert("Connexion Supabase indisponible.");

      const btn = document.getElementById("resetPlayerAccessBtn");
      btn.disabled = true;
      btn.textContent = "RÉINITIALISATION…";
      try {
        const { data, error } = await client.rpc("reset_player_access");
        if (error) throw error;
        alert(`${Number(data) || 0} accès joueur(s) libéré(s). Les mêmes codes peuvent maintenant être réutilisés sur d'autres appareils.`);
      } catch (e) {
        alert(e.message || "Impossible de réinitialiser les accès joueurs.");
      } finally {
        btn.disabled = false;
        btn.textContent = "RESET ACCÈS JOUEURS";
      }
    });

    document.getElementById("resetAllAccessBtn").addEventListener("click", async () => {
      if (!confirm("ATTENTION : cette commande libère aussi les codes Organisateur, y compris celui utilisé sur cet appareil. Continuer ?")) return;
      const typed = prompt("Pour confirmer, écris exactement : RESET ACCES");
      if ((typed || "").trim().toUpperCase() !== "RESET ACCES") {
        alert("Réinitialisation annulée.");
        return;
      }

      const client = getClient();
      if (!client) return alert("Connexion Supabase indisponible.");

      const btn = document.getElementById("resetAllAccessBtn");
      btn.disabled = true;
      btn.textContent = "RÉINITIALISATION…";
      try {
        const { data, error } = await client.rpc("reset_all_access");
        if (error) throw error;
        alert(`${Number(data) || 0} accès libéré(s). Tous les codes sont de nouveau disponibles. Tu vas être déconnecté de l'interface Organisateur.`);
        try { await client.auth.signOut(); } catch (_) {}
        window.location.reload();
      } catch (e) {
        btn.disabled = false;
        btn.textContent = "RESET TOUS LES ACCÈS";
        alert(e.message || "Impossible de réinitialiser tous les accès.");
      }
    });
  }

  injectAccessResetControls();
  setTimeout(injectAccessResetControls, 100);
})();
