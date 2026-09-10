# Audit de sécurité local — 10 septembre 2026

## Conclusion et périmètre

La lecture complète des deux scripts et du README du commit `3d1bea4` n'a
révélé aucun comportement manifestement malveillant : pas de code obfusqué,
de commande téléchargée puis exécutée par le script d'usage, de collecte de
conversations, de suppression de données personnelles ni de destination réseau
tierce pour les identifiants. Cela ne constitue pas une garantie d'innocuité de
futures versions, des exécutables installés sur la machine ou du service distant.

Le script d'usage lit `auth.json`, copie **tout son contenu** dans
`auth-poll.json`, puis utilise les jetons d'accès des comptes ChatGPT pour
interroger `https://chatgpt.com/backend-api/wham/usage`. Les clés API ne sont pas
envoyées par cette branche. La commande `switch` remplace le fichier d'identité
active. L'installateur écrit un exécutable et ajoute un bloc PATH/alias au fichier
de configuration du shell. Ces écritures correspondent aux fonctions annoncées.

## Problèmes constatés et corrections

| Importance | Problème initial | Correction locale |
| --- | --- | --- |
| Élevée selon la visibilité des processus | Le jeton figurait dans les arguments de `curl` ; les objets d'authentification complets et les clés API dans ceux de `jq`. | En-têtes via l'entrée standard ; objets via des fichiers privés ; suppression de l'identité secrète inutile dans les résultats. |
| Élevée si les paramètres d'installation sont contrôlés par un tiers | Le chemin, l'alias et le nom de commande étaient interpolés dans du code shell sans protection suffisante. | Validation des noms et citation POSIX du chemin ; tests avec apostrophes, backticks et substitution de commande. |
| Modérée | Le changement de compte tronquait directement `auth.json`, avec risque de corruption et conservation de permissions trop larges. | Écriture temporaire dans le même dossier puis renommage, permissions `0600`, refus des liens symboliques et détection d'un changement depuis le début de la sélection. |
| Modérée | L'installation téléchargeait directement sur l'exécutable existant depuis une branche mutable. | Priorité au script local, téléchargement temporaire avec délais et HTTPS imposé, validation syntaxique et remplacement atomique. La vérification cryptographique du code distant reste absente. |
| Modérée | Validation incomplète du pool et des valeurs utilisées dans les en-têtes. | Validation du document entier, des types et des caractères de contrôle avant mise à jour ; refus d'utiliser le même fichier pour l'identité active et le pool. |
| Modérée | Les requêtes acceptaient la configuration implicite de curl et pouvaient rester bloquées sans limite. | `.curlrc` désactivé, aucun suivi de redirection pour les requêtes authentifiées, délais de connexion et de requête, limite de taille demandée à curl. |
| Modérée | Des valeurs affichées pouvaient contenir des séquences de contrôle du terminal ; `%b` interprétait aussi les séquences échappées. | Filtrage des chaînes des résultats et affichage avec `%s` ; couleurs désactivées en sortie redirigée ou avec `NO_COLOR`. |
| Fiabilité | Une fin d'entrée était interprétée comme une confirmation ; une flèche en bord de liste pouvait arrêter le programme avec `set -e`. | Terminal obligatoire, annulation à la fermeture de l'entrée, délai pour les séquences de touches et conditions explicites aux bords de liste. |
| Fiabilité | Deux mises à jour du pool pouvaient s'écraser ; les temporaires n'étaient pas tous nettoyés. | Verrou exclusif pendant la mise à jour, copie privée pour les lectures suivantes et nettoyage groupé à la sortie normale, sur SIGINT et SIGTERM. |

## Validation

Les 13 tests de `tests/test_security.py` passent et utilisent uniquement des identifiants
fictifs, des fichiers temporaires et un faux `curl`. Un lanceur de test pour
`jq` vérifie aussi l'absence des secrets fictifs dans ses arguments. Le test
interactif utilise un pseudo-terminal et vérifie le compte effectivement écrit.

```bash
bash -n install.sh show_codex_usage.sh
python3 -m unittest discover -s tests -v
```

Aucun accès aux identifiants réels de l'utilisateur, aucune requête authentifiée
réelle et aucune installation dans son shell n'ont été réalisés. Les tests sont
exécutés sous Linux ; la compatibilité macOS n'a pas été testée. ShellCheck
n'était pas disponible dans cet environnement.

## Limites restantes

- Le pool conserve des secrets en clair, nécessaires à la fonction de changement
  de compte. Le mode `0600` n'isole pas les autres processus du même utilisateur.
- Le dossier contenant les identifiants doit être privé. Les vérifications de
  chemins ne constituent pas une protection complète contre un processus local
  capable de modifier ces dossiers entre deux opérations.
- Le verrou du pool est partagé uniquement par les instances de ce script.
  La comparaison de `auth.json` avant remplacement réduit les écrasements
  concurrents mais n'est pas une transaction avec les autres programmes.
- SIGKILL ou une panne peuvent laisser des temporaires sensibles et un verrou.
- Le mode d'installation distant fait toujours confiance à la source choisie.
  Lancer `bash install.sh` depuis ce dépôt utilise les corrections locales.
- L'endpoint est présenté comme interne par le projet. Son fonctionnement réel,
  notamment après simplification des en-têtes navigateur, n'a pas été vérifié
  contre le service. Un jeton expiré ou un changement de service peut empêcher
  la consultation. Le script ne renouvelle pas les jetons.
