# Quota Codex

Une petite page locale qui affiche le quota restant et les dates de remise à zéro. Le navigateur ne reçoit jamais les identifiants Codex. Le serveur les lit depuis `~/.codex/auth.json` et interroge l’endpoint d’usage côté serveur.

![Aperçu de la page : une jauge de quota et les informations de remise à zéro](docs/screenshot-placeholder.svg)

## Démarrer

Node 20 ou plus récent suffit. Il n’y a aucune dépendance à installer.

```bash
cp .env.example .env
# Renseigne DASHBOARD_API_KEY dans .env, puis charge la configuration.
set -a; source .env; set +a
npm start
```

Ouvre ensuite `http://localhost:8000`. Le serveur écoute par défaut sur toutes les interfaces réseau (`0.0.0.0`).

Le serveur attend une réponse JSON semblable à celle de l’endpoint d’usage Codex :

```json
{
  "plan_type": "plus",
  "rate_limit": {
    "limit_reached": false,
    "primary_window": { "used_percent": 29, "reset_at": 1730000000 },
    "secondary_window": { "used_percent": 12, "reset_at": 1730500000 }
  }
}
```

Il accepte aussi les champs `used_percent`, `reset_at`, `weekly_used_percent` et `weekly_reset_at` à la racine. La jauge représente la fenêtre courte. La couleur passe au jaune sous 25 %, puis au rouge sous 10 %.

## Configuration

Le serveur utilise par défaut `~/.codex/auth.json` et l’endpoint d’usage Codex. `CODEX_AUTH_FILE` et `USAGE_API_URL` permettent de remplacer ces valeurs. `HOST` et `PORT` valent respectivement `0.0.0.0` et `8000` par défaut. Toutes les routes `/api/*` exigent la valeur de `DASHBOARD_API_KEY` dans l’en-tête `X-API-KEY`.

Ne mets jamais le contenu de `auth.json` dans `public/`, dans le README ou dans du JavaScript côté navigateur.

Le serveur limite les appels à dix secondes, refuse les redirections de l’API distante et ne met pas les réponses en cache. Il doit rester derrière un réseau de confiance ou une authentification si tu le déploies : l’interface elle-même n’ajoute pas de connexion utilisateur.

## Vérifier

```bash
npm test
```

Les tests ne font aucun appel réseau et ne nécessitent pas de clé.

## Scripts historiques

`show_codex_usage.sh` et `install.sh` restent dans le dépôt pour l’outil de terminal existant. Leur audit local est disponible dans [AUDIT.md](AUDIT.md).
