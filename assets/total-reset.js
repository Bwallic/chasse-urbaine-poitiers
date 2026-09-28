(() => {
  function injectTotalReset() {
    const actions = document.querySelector('.access-reset-actions');
    if (!actions || document.getElementById('resetTotalTestBtn')) return;

    const button = document.createElement('button');
    button.id = 'resetTotalTestBtn';
    button.className = 'ghost';
    button.textContent = 'RESET TOTAL TEST';
    actions.appendChild(button);

    const info = document.createElement('p');
    info.className = 'muted compact';
    info.innerHTML = '<strong>RESET TOTAL TEST</strong> : remet la partie entièrement à zéro (pings, START, zone d\'extraction, appareils et pseudos) tout en conservant les codes, rôles et équipes.';
    actions.parentElement?.appendChild(info);

    button.addEventListener('click', async () => {
      if (!confirm('RESET TOTAL TEST : remettre entièrement la session à zéro ? Les pings, le START, la zone active, les associations appareils et les pseudos seront effacés. Les codes, rôles et équipes seront conservés.')) return;
      const typed = prompt('Pour confirmer, écris exactement : RESET TOTAL');
      if ((typed || '').trim().toUpperCase() !== 'RESET TOTAL') {
        alert('Réinitialisation annulée.');
        return;
      }

      const client = window.CHASSE_LIVE_CLIENT;
      if (!client) return alert('Connexion Supabase indisponible.');

      button.disabled = true;
      button.textContent = 'RÉINITIALISATION…';

      try {
        const { data, error } = await client.rpc('reset_total_test');
        if (error) throw error;
        alert(`${Number(data) || 0} participant(s) réinitialisé(s). La session de test est revenue à zéro. Tu vas être déconnecté afin de pouvoir reprendre avec un code neuf.`);
        try { await client.auth.signOut(); } catch (_) {}
        window.location.reload();
      } catch (e) {
        button.disabled = false;
        button.textContent = 'RESET TOTAL TEST';
        alert(e.message || 'Impossible de réinitialiser complètement la session de test.');
      }
    });
  }

  injectTotalReset();
  setTimeout(injectTotalReset, 100);
})();
