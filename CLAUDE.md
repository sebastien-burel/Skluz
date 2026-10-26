# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## État du dépôt

Les **10 phases** de `PLAN_SKLUZ.md` sont implémentées, plus la réadoption des tunnels orphelins (hors plan, décidée avec Sébastien). Le projet est fonctionnel ; la v1.0 est signée, notarisée et validée sur une autre machine (DMG produit par `Tools/release.sh`, cf. `NOTARIZATION.md`).

**Chantier en cours : `docs/PLAN_SKLUZD.md`** — daemon root `skluzd` (via `SMAppService.daemon`) + CLI `skluz`, pour ouvrir des tunnels « Système » sans session graphique (Mac mini déverrouillé par SSH). 8 phases, validation de Sébastien entre chacune. Phase 0 faite (audit et décisions D1–D6 validées dans `docs/AUDIT_SKLUZ.md` §9) ; phase 1 (package `SkluzCore`) validée ; phase 2 (daemon `skluzd` en exécution manuelle) validée ; phase 3 (launchd via `SMAppService`) validée ; phase 4 (API XPC) validée ; phase 5 (clés dédiées et clés d'hôte) validée ; phase 6 (UI de l'app) à venir.

**Autorité par mode** : `PLAN_SKLUZ.md` fait autorité pour le **mode Session** (l'app de barre de menus, comportement v1) ; `docs/PLAN_SKLUZD.md` fait autorité pour le **mode Système** (daemon, XPC, CLI, clés dédiées). Si tu détectes une contradiction entre ce CLAUDE.md et un plan, le plan gagne (signale-la à Sébastien). Continuer à valider visuellement chaque changement notable avant de l'enchaîner.

## Ce que Skluz est

Gestionnaire de tunnels SSH macOS, app **menu bar uniquement** (`LSUIElement = YES`, pas d'icône Dock, pas de fenêtre principale). Chaque tunnel est un `Process` qui lance `/usr/bin/ssh`. État persisté en JSON dans `~/Library/Application Support/Skluz/tunnels.json`.

- **Plateforme** : macOS 26.5+ (Tahoe), Swift 6 strict concurrency, SwiftUI + AppKit (`NSStatusItem`).
- **Bundle ID** : `net.haruni.skluz` — éditeur Haruni SAS.
- **Distribution** : Developer ID signé + notarisé, **pas App Store** (besoin de `Process`, sandbox désactivé).

## Architecture en deux mots

Le code partagé par l'app, le futur daemon `skluzd` et la CLI vit dans le package local **`SkluzCore/`** (phase 1 de `PLAN_SKLUZD`) :

- **`TunnelConfig`** : modèle unique, avec `mode` (`.session` / `.system`) ; `tunnels.json` en schéma v2, migré depuis la v1 avec sauvegarde `tunnels.v1.json`.
- **`SSHCommandBuilder`** : validation des champs puis deux politiques (Session = v1 inchangée, Système = liste blanche).
- **`TunnelStore`** (actor) : persistance JSON + état en mémoire de la liste des tunnels.
- **`TunnelSupervisor`** (actor, ex-`TunnelRunner`) : cycle de vie des `Process` SSH (start/stop/restart, capture stderr → `LogStore`, `RestartPolicy` par mode, réaction réseau via `NetworkMonitor` en mode Système). Ses effets de bord (exécutable ssh, horloge, `sleep`, aléa) passent par `Environment` : `.live` en production, injecté seulement par les tests. Les faux ssh des tests tournent en `/bin/sh <script>` (`leadingArguments`), jamais comme exécutables neufs : macOS peut suspendre indéfiniment à `_dyld_start` un exécutable tout juste écrit.

L'app (`Skluz/`) garde l'UI, `SSHConfigParser`, `TunnelTester`, `LaunchAtLoginManager` et `DaemonManager` (`SMAppService.daemon`, refuse d'enregistrer hors de `/Applications/Skluz.app`). Le build de l'app embarque `skluzd` dans `Contents/MacOS/` et `LaunchDaemons/net.haruni.skluzd.plist` dans `Contents/Library/LaunchDaemons/` (phases Copy Files) ; `Tools/release.sh` vérifie leur présence et leur signature.

Le daemon (`skluzd/`, cible outil `net.haruni.skluzd`) : `main.swift` (arguments, signaux `SIGTERM`/`SIGINT`/`SIGHUP`), `Daemon` (actor : `SystemLayout.loadTunnels` puis `TunnelReconciler`), `Log` (`os.Logger`, subsystem `net.haruni.skluzd`, recopié sur stderr dans un terminal). `--base-dir` n'existe que pour le développement et est **refusé en root**. XPC (`XPCServer`, Mach service `net.haruni.skluzd.xpc`, actif seulement sous launchd) : contrat `SkluzDaemonProtocol` et `DaemonClient` dans `SkluzCore/DaemonAPI.swift` et `DaemonClient.swift` ; requirement client avec les identifiants **entre parenthèses**, mutations réservées au groupe `admin`, écriture de la config via `SystemLayout.saveTunnels` (fichier temporaire `600` puis `rename`).

L'UI SwiftUI observe via `@Observable` (macros Swift 6), **pas de Combine**. Tous les modèles traversant les frontières d'actor doivent être `Sendable`.

Voir `PLAN_SKLUZ.md` §2 pour l'arborescence cible des fichiers, §4 pour le modèle de données, §6 pour le cycle de vie d'un tunnel.

## Méthode de travail

Les plans imposent un découpage **phase par phase** (10 phases pour `PLAN_SKLUZ.md`, terminées ; 8 pour `PLAN_SKLUZD.md`, en cours). Règles à respecter :

- **Implémenter une seule phase à la fois.** Faire valider visuellement par Sébastien avant de passer à la suivante.
- Chaque phase doit être **compilable et testable** à elle seule.
- **Demander plutôt qu'inventer** : si une décision d'archi n'est pas dans le plan, poser la question.
- Si tu vois un bug dans le plan lui-même, le signaler **avant** d'écrire du code basé dessus.

## Invariants critiques (à ne jamais enfreindre)

Ces points sont des sources de bugs subtils ou de failles de sécurité — toute déviation doit être justifiée explicitement.

### Communs aux deux modes

- **Chemin SSH** : toujours `/usr/bin/ssh` en absolu. Jamais de résolution `PATH`.
- **Jamais de shell** : passer les arguments via `Process.arguments` (tableau). **Ne jamais** construire une string et l'envoyer à `/bin/sh` — ouvre la porte à l'injection.
- **`-N -T`** (pas de commande, pas de pty) et **`-o ExitOnForwardFailure=yes`** — crucial : un port local déjà pris doit faire sortir ssh immédiatement plutôt que de laisser un process zombie.
- **Validation des champs** (introduite en phase 1 de `PLAN_SKLUZD`) avant toute construction de commande : host/user sans `-` initial, ports 1–65535, aucun caractère de contrôle.
- **`~/.ssh/config` n'est jamais écrit.** Aucune modification, jamais.
- **Logs en buffer circulaire** (1000 lignes max par tunnel). Un tunnel verbeux sur plusieurs jours ne doit pas consommer toute la RAM.
- **Lecture continue des `Pipe`** stdout/stderr (`readabilityHandler` ou `bytes`) — sinon SIGPIPE bloque le child.
- **Persistance atomique** : écriture en fichier temporaire puis `rename`.

### Mode Session (app, sous l'UID de l'utilisateur — `PLAN_SKLUZ.md` §5)

- `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`.
- `-o StrictHostKeyChecking=accept-new` — accepter les nouveaux hosts, refuser les changements de clé. **Ne jamais désactiver** host key checking par défaut.
- `~/.ssh/config` est lu (alias, options) ; `proxyJump` et `extraArgs` libres autorisés.
- **Pas de stockage de credentials** : clés de l'utilisateur + agent système. Pas de mot de passe, pas de Keychain.

### Mode Système (daemon root — `docs/PLAN_SKLUZD.md`)

- **Liste blanche stricte** : la commande est construite uniquement depuis les champs typés de `TunnelConfig`. Jamais de `-o` libre, `ProxyCommand`, `LocalCommand`, `KnownHostsCommand`, `proxyJump` ni `extraArgs` — une option arbitraire = exécution de code en root.
- `-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes` avec `known_hosts` dédié (`GlobalKnownHostsFile=/dev/null`) ; une clé d'hôte n'est ajoutée qu'après confirmation explicite de l'utilisateur. **Jamais `accept-new`.**
- `-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes`, `user` obligatoire, écoute sur `127.0.0.1` sauf opt-in explicite (`exposesOnNetwork`).
- Clé passée par `-o IdentityFile="…"`, **jamais `-i`** (un `-i` absent fait retomber ssh sur les clés de root) ; chemins de `UserKnownHostsFile`/`IdentityFile` **entre guillemets** (ssh coupe sur les espaces).
- **Seul stockage de secrets du projet, assumé** : clés privées dédiées **sans passphrase** dans `/Library/Application Support/Skluz/keys/` (`600 root:wheel`), compensées par une ligne `authorized_keys` restreinte côté serveur (`restrict,port-forwarding,permitopen=…,command="/bin/false"` : sans `command=`, `restrict` laisse la clé exécuter des commandes).
- Fichiers root refusés s'ils n'appartiennent pas à root, sont trop ouverts ou sont des liens symboliques — le daemon reste vivant et expose l'erreur, il ne corrige jamais seul.
- XPC : requirement de signature Team `82FW35VV68` **avec les identifiants entre parenthèses** ; appels de mutation et `fetchHostKey` réservés au groupe `admin`.
- **App installée au nom de root** : launchd ne vérifie que la signature d'équipe de `skluzd` ; un bundle modifiable par l'utilisateur permettrait d'y glisser un autre `skluzd` signé (ancienne version) lancé en root. `DaemonManager` refuse donc l'activation tant que `InstallationCheck` signale un problème (`sudo chown -R root:wheel /Applications/Skluz.app && sudo chmod -R go-w /Applications/Skluz.app`).

## Tests minimaux attendus

Au minimum un test unitaire sur **la construction des arguments SSH** (`SSHCommandBuilder`) : donner un `TunnelConfig`, vérifier le tableau d'args produit. C'est là que les régressions silencieuses se cachent (le tunnel "marche" mais avec les mauvaises options). En mode Système, tester aussi les **rejets** (injection d'options, champs invalides).

## Commandes courantes

Scheme : `Skluz`. Cibles de test : `SkluzCoreTests` (package, l'essentiel des tests) et `SkluzTests` (app, Swift Testing) ;
`SkluzUITests` est du boilerplate neutralisé (app menu bar sans fenêtre).

```sh
# Build Debug
xcodebuild -project Skluz.xcodeproj -scheme Skluz -configuration Debug \
  -destination 'platform=macOS' build

# Tests de l'app (SkluzTests)
xcodebuild -project Skluz.xcodeproj -scheme Skluz -destination 'platform=macOS' test

# Tests du package SkluzCore (builder, superviseur avec faux ssh, store…)
swift test --package-path SkluzCore

# Daemon : build, puis exécution manuelle (Ctrl-C = SIGTERM propre)
xcodebuild -project Skluz.xcodeproj -scheme skluzd -configuration Debug \
  -destination 'platform=macOS' build
sudo "$(xcodebuild -project Skluz.xcodeproj -scheme skluzd -showBuildSettings \
  2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/skluzd"

# Journaux du daemon (/usr/bin/log : sous zsh, `log` est une commande interne)
/usr/bin/log show --last 10m --info --predicate 'subsystem == "net.haruni.skluzd"'

# Tunnel Système de test, en attendant l'UI (phases 4–6)
sudo Tools/skluzd-dev-setup.sh vllm sb@dgx.haruni.net 2022 18000 localhost 8000

# Sonde XPC (3 variantes : non signée, ad hoc, équipe) pour tester le daemon installé
Tools/xpc-probe/build.sh && build/xpc-probe/team-cli status

# Test ciblé (Swift Testing : Suite/fonction)
xcodebuild -project Skluz.xcodeproj -scheme Skluz -destination 'platform=macOS' \
  test -only-testing:SkluzTests/SSHCommandBuilderTests/localForwardWithUserAndCustomSSHPort

# Lancer l'app buildée (chemin DerivedData variable selon la machine)
open -n "$(xcodebuild -project Skluz.xcodeproj -scheme Skluz -showBuildSettings \
  2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Skluz.app"
```

Régénérer l'AppIcon : `swift Tools/generate_appicon.swift`.
Signature Developer ID + notarisation : voir `NOTARIZATION.md`.

## Langue

- Conversations et issues internes : **français** (Sébastien est francophone, le plan est en français).
- Identifiants, commentaires de code, messages de commit : **anglais** (cf. préférences globales).
- Strings d'UI utilisateur : français par défaut en v1. Une localisation breton (`br`) est listée en extension future (cf. §13 du plan), à ignorer pour l'instant.
