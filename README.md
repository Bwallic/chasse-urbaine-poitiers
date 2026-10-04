# Évasion Urbaine — Poitiers

Prototype V1 de l'application web mobile pour l'événement du 28 octobre 2026.

## Fonctionnalités présentes

- Carte commune Leaflet avec fond sombre OpenStreetMap/CARTO.
- Périmètre, prison et 5 zones d'extraction importés depuis le KMZ Google Earth fourni.
- Trois rôles : Cible, Chasseur, Organisateur.
- Cible : envoi automatique du ping GPS lorsque l'application est visible au créneau prévu, avec notification/clic ou bouton manuel en secours.
- Chasseur : affichage centralisé du dernier ping connu de chaque Cible.
- Organisateur : matrice de contrôle de Ping 0 puis des pings toutes les 20 minutes jusqu’à +120 minutes et tirage aléatoire de la zone d'extraction.
- Conservation de l'historique des pings côté Supabase.
- Heure du ping calculée côté serveur dans la version connectée.
- Contrôle automatique de la fenêtre ±60 secondes.
- Realtime Supabase pour actualiser les pings et la zone active sur les autres téléphones.
- Mode démo local pour tester l'interface sans backend.

## Structure

- `index.html` : interface unique mobile.
- `assets/app.js` : logique Cible / Chasseur / Organisateur.
- `assets/styles.css` : interface sombre.
- `data/areas.geojson` : géométries exactes extraites du KMZ.
- `config.js` : configuration du site.
- `supabase/schema.sql` : tables, RLS et fonctions serveur.
- `supabase/seed-event.sql` : événement, zones et 7 créneaux de ping (Ping 0 à Ping 6).
- `supabase/seed-participants-example.sql` : exemple de création de participants et codes.
- `scripts/kmz_to_geojson.py` : conversion/reconstruction des zones depuis un KMZ.

## Tester immédiatement en mode démo

`config.js` est livré avec `DEMO_MODE: true`.

Servir le dossier par HTTP, par exemple :

```bash
python -m http.server 8000
```

Puis ouvrir `http://localhost:8000`.

La géolocalisation du navigateur fonctionne normalement en HTTPS. `localhost` est également autorisé par les navigateurs modernes pour les tests.

## Passer en mode multijoueur avec Supabase

1. Créer un projet Supabase.
2. Dans l'éditeur SQL Supabase, exécuter `supabase/schema.sql`.
3. Exécuter `supabase/seed-event.sql`.
4. Activer les connexions anonymes dans Authentication > Providers > Anonymous.
5. Créer les vrais participants et leurs codes sur le modèle de `seed-participants-example.sql`.
6. Dans `config.js`, renseigner `SUPABASE_URL` et `SUPABASE_ANON_KEY`, puis mettre `DEMO_MODE: false`.

L'anon key Supabase peut être présente dans une application web publique : la protection repose sur les règles RLS. Ne jamais mettre la `service_role` key dans ce dépôt.

## GitHub Pages

Le front-end est statique et peut être publicé directement avec GitHub Pages.

1. Créer un dépôt, par lexemple `evasion-urbaine-poitiers`.
2. Ajouter le contenu de ce dossier à la branche `main`.
3. Dans les paramètres du dépôt, activer Pages à partir de la branche `main` / racine du dépôt.
4. Utiliser l'URL HTTPS fournie par GitHub Pages.

L'https est important : la géolocalisation navigateur exige un contexte sécurisé hors `localhost`.

## Codes d'accès

Chaque participant dispose d'un code personnel. Au premier usage, le code est associé à l'identité anonyme Supabase du navigateur. Un code ne peut ensuite pas être utilisé sur un autre appareil sans réinitialisation de son `user_id` par l'organisateur dans la base.

Les vrais codes doivent rester dans Supabase. Ne pas committer un fichier contenant les codes réels dans un dépôt public.

## Logique des pings

La base utilise un Ping 0 au START, puis un ping toutes les 20 minutes pendant les deux heures du jeu : Ping 1 à +20, Ping 2 à +40, Ping 3 à +60, Ping 4 à +80, Ping 5 à +100 et Ping 6 à +120 minutes. `sent_at` vient de l'horloge du serveur. Un ping est valide si son écart au créneau est inférieur ou égal à 60 secondes. Les pings hors fenêtre sont conservés et signalés à l'organisateur.

## Zone d'extraction

Les cinq zones sont visibles dès le départ. L'organisateur utilise « Tirer la zone » au moment prévu par les règles de la partie. Le serveur choisit aléatoirement une zone et la conserve : un second clic renvoie la même zone au lieu d'en tirer une nouvelle.

## Plan B recommandé

Pour la première édition, conserver le groupe WhatsApp prévu dans les règles : en cas de problème de réseau ou de backend, chaque Cible peut envoyer sa position dans le groupe général.
