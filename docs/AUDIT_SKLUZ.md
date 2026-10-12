# Audit de Skluz avant le daemon `skluzd`

> Phase 0 de [`PLAN_SKLUZD.md`](PLAN_SKLUZD.md). État audité : commit
> `ff0cb16` (v1.0 notarisée). Aucun code modifié.

## 1. Lancement des tunnels

- **Mécanisme** : `Foundation.Process` qui exécute `/usr/bin/ssh` (chemin
  absolu, sans `PATH`), arguments passés en tableau, sans shell. Ni libssh ni
  SwiftNIO SSH. Version système actuelle : OpenSSH 10.3p1.
- **Construction** : `Skluz/Services/SSHCommandBuilder.swift`, enum
  `nonisolated`, fonction pure `arguments(for: Tunnel) -> [String]`. Elle est
  utilisée par `TunnelRunner` et par `TunnelTester` (bouton « Tester »).
- **Options produites, dans l'ordre** :
  1. `-N -T -o ServerAliveInterval=30 -o ServerAliveCountMax=3`
     `-o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new` ;
  2. `-p <port>` si `sshPort` ;
  3. `-i <chemin>` (tilde étendu) `-o IdentitiesOnly=yes` si `identityFile` ;
  4. `-J <proxyJump>` si présent ;
  5. `-L local:remoteHost:remotePort`, `-R …` ou `-D local` selon `type` ;
  6. `[user@]host` ;
  7. `extraArgs` libres, en dernier. OpenSSH relit les options placées après
     l'hôte (vérifié avec `ssh … host -v`).
- **Pas de `-F`** : `~/.ssh/config` et `/etc/ssh/ssh_config` s'appliquent, y
  compris les alias d'hôte. C'est voulu en v1 (cf. `PLAN_SKLUZ.md` §7).
- **Aucune validation des champs**. Un `sshHost` ou un `sshUser` commençant
  par `-` serait lu comme une option. `extraArgs` accepte n'importe quoi,
  y compris `-oProxyCommand=…`. Le risque est acceptable tant que ssh tourne
  sous l'UID de l'utilisateur, mais ce code ne doit pas être repris tel quel
  dans un processus root.
- **Bind local implicite** : la spécification `-L` ne contient pas d'adresse ;
  l'écoute se fait donc sur la boucle locale (`GatewayPorts no` par défaut),
  sauf si `~/.ssh/config` en décide autrement.
- **Tests existants** : 9 tests `SSHCommandBuilderTests`, plus des tests sur
  la persistance, le registre de PID, le parseur de config et le backoff
  (Swift Testing, cible `SkluzTests`).

## 2. Stockage de la configuration

- Fichier JSON `~/Library/Application Support/Skluz/tunnels.json`, géré par
  l'actor `TunnelStore`. Format `{ "version": 1, "tunnels": [Tunnel] }`.
  Écriture via `Data.write(options: .atomic)`, c'est-à-dire fichier temporaire
  puis `rename`. Une version de schéma supérieure à celle connue est refusée.
- Registre séparé `runtime.json` (`RuntimePIDStore`) : correspondance tunnel →
  PID ssh, utilisée pour réadopter les ssh orphelins après un crash de l'app.
- Pas d'`UserDefaults` ni de trousseau pour la configuration.
- Modèle `Tunnel` (`Skluz/Models/Tunnel.swift`) : `id`, `name`, `type`
  (`localForward` / `remoteForward` / `dynamic`), `sshHost`, `sshUser?`,
  `sshPort?`, `identityFile?` (chemin), `localPort`, `remoteHost?`,
  `remotePort?`, `proxyJump?`, `extraArgs`, `autoStart`, `autoRestart` et
  `enabled`.
- **Configuration réelle sur ce poste** : 6 tunnels, tous `localForward`. Ils
  utilisent des noms d'hôte complets (pas d'alias), sans `proxyJump` ni
  `extraArgs`, avec une clé explicite.

## 3. Clés et passphrases

- Skluz ne stocke aucun secret. L'authentification passe par le chemin
  `identityFile` passé à `-i`, ou à défaut par l'agent ssh de la session et
  `~/.ssh/config`.
- Les passphrases sont gérées par l'agent ou le trousseau de session macOS
  (`UseKeychain`), hors de Skluz. Elles ne sont donc **pas disponibles avant
  connexion**.
- Les clés utilisées ici se trouvent dans `~/.ssh/` et dans
  `~/Library/Application Support/NVIDIA/Sync/config/`. Elles appartiennent à
  l'utilisateur. Un daemon root pourrait techniquement les lire, mais le plan
  impose des clés dédiées sous `/Library/Application Support/Skluz/keys/`.
  Le passage en mode Système implique donc de générer une nouvelle clé et de
  l'installer côté serveur, et non de réutiliser l'existante.

## 4. Supervision et reconnexion

- Actor `TunnelRunner` :
  - démarrage : état `.starting`, puis `.running` si le process est toujours
    vivant après 500 ms ;
  - arrêt : SIGTERM, attente de 3 s, puis SIGKILL ;
  - sortie de l'app : `stopAll()` en parallèle (`applicationShouldTerminate`
    → `.terminateLater`) ;
  - pipes stdout et stderr lus en continu via `readabilityHandler`, avec une
    garde EOF (correctif `d15e4dd`) ; stderr est copié dans `LogStore`
    (tampon circulaire de 1000 lignes par tunnel).
- **Reconnexion** : seulement si `autoRestart` et code de sortie ≠ 0. Le
  backoff suit une table fixe de 2, 5, 15, 30 et 60 s, sans jitter, et
  **abandonne après 5 tentatives** (`.failed`). Le compteur repart de zéro
  dès qu'un ssh est encore vivant après 500 ms. Un ssh qui échoue lentement
  (serveur injoignable, clé refusée après l'échange) remet donc le compteur à
  zéro à chaque essai, et la limite de 5 tentatives n'est en pratique jamais
  atteinte : le tunnel réessaie indéfiniment toutes les 2 s.
- **Pas de `NWPathMonitor`** : la perte du réseau n'est détectée que par
  `ServerAlive*` (≈ 90 s), puis passe par le backoff.
- **Pas d'`os.Logger`** : les seuls logs sont le stderr de ssh en mémoire.
- **Réadoption** : au lancement, les PID de `runtime.json` encore vivants
  dont l'exécutable se termine par `/ssh` sont réadoptés et surveillés par
  polling toutes les 2 s.
- **Bug trouvé** : `autoStart` (« Démarrer au lancement » dans l'éditeur) est
  persisté mais **lu nulle part**. Au lancement, l'app ne démarre aucun
  tunnel ; seuls les orphelins sont réadoptés. Sur ce poste, 3 tunnels ont
  `autoStart = true`.

## 5. Cible, sandbox, signature, notarisation

- `MACOSX_DEPLOYMENT_TARGET = 26.5`. Le Mac mini est sous macOS 27 ; ce poste
  aussi (27.0.1).
- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` et
  `SWIFT_APPROACHABLE_CONCURRENCY = YES` sur la cible app. C'est pour cela
  que les modèles et les services purs sont marqués `nonisolated`. Un package
  SPM est `nonisolated` par défaut, ce qui ne pose pas problème : il suffira
  de rendre publics les types partagés.
- `ENABLE_APP_SANDBOX = NO`, aucun fichier `.entitlements`.
  `ENABLE_HARDENED_RUNTIME = YES`. `LSUIElement = YES` (pas d'icône Dock).
- **Sandbox** : l'app n'est pas sandboxée, donc `SMAppService.daemon` est
  utilisable sans retirer quoi que ce soit. Point non bloquant.
- Signature automatique, Team `82FW35VV68` (« Developer ID Application:
  HARUNI »). Notarisation et DMG via `Tools/release.sh` ; v1.0 validée sur le
  Mac mini.
- Projet Xcode `objectVersion = 77` avec groupes synchronisés
  (`PBXFileSystemSynchronizedRootGroup`) et 3 cibles : `Skluz`, `SkluzTests`
  et `SkluzUITests` (boilerplate). Aucun package SPM pour l'instant.

## 6. Lancement à l'ouverture de session

- `SMAppService.mainApp` via `Skluz/App/LaunchAtLoginManager.swift`, réglable
  dans `PreferencesView`. L'état `.requiresApproval` est déjà géré (message +
  bouton « Ouvrir les Réglages Système »). Ce schéma sera repris pour
  `DaemonManager`.
- Ce mécanisme ne fonctionne qu'après ouverture d'une session graphique,
  d'où le besoin d'un daemon.

## 7. Écarts avec l'architecture cible

| Sujet | Existant | Cible `PLAN_SKLUZD` |
|---|---|---|
| Structure | 1 cible app | package `SkluzCore` + cibles `skluzd` et `skluz` |
| Modèle | `Tunnel` (type, proxyJump, extraArgs, autoRestart…) | `TunnelConfig` (mode, keyRef, localBindAddress), sans type, proxyJump ni extraArgs |
| Builder | permissif, sans validation | liste blanche stricte, validation par regex |
| Host keys | `accept-new` | `yes` + `known_hosts` dédié, confirmation explicite |
| Config ssh | `~/.ssh/config` lu | `-F /dev/null` |
| Keepalive | 30 s × 3 | 15 s × 3 |
| Backoff | table fixe, 5 tentatives | 1 → 60 s exponentiel + jitter |
| Réseau | aucun suivi | `NWPathMonitor` |
| Logs | stderr en mémoire | `os.Logger` (`net.haruni.skluzd`) |
| IPC | aucune | XPC Mach service `net.haruni.skluzd.xpc` |
| Lancement | `SMAppService.mainApp` | + `SMAppService.daemon` |

Conséquences :

- **Une migration stricte vers `TunnelConfig` casserait les tunnels Session**
  (perte de `-R`, `-D`, `proxyJump`, `extraArgs`, `autoRestart`, et des alias
  de `~/.ssh/config`). Cela contredit la phase 1, qui demande « sans
  changement de comportement visible ». Il faut deux politiques, une par mode
  (cf. D2).
- **Les invariants de `CLAUDE.md` et de `PLAN_SKLUZ.md` §5 sont contredits
  par le mode Système** : `accept-new`, « `~/.ssh/config` est lu », « pas de
  stockage de credentials ». Ils doivent être amendés explicitement (cf. D1).

## 8. Points du plan à corriger avant tout code

1. **Requirement XPC mal parenthésée (faille de sécurité).** Dans le langage
   des code requirements, `and` est prioritaire sur `or`. La chaîne du plan
   se lit donc
   `(anchor apple generic and OU = 82FW35VV68 and identifier "net.haruni.skluz") or identifier "net.haruni.skluz.cli"`.
   **N'importe quel binaire, même signé ad hoc, déclarant l'identifiant
   `net.haruni.skluz.cli` serait accepté** et pourrait piloter un daemon root.
   Correction :
   ```
   anchor apple generic and certificate leaf[subject.OU] = "82FW35VV68"
     and (identifier "net.haruni.skluz" or identifier "net.haruni.skluz.cli")
   ```
   Le test de la phase 4 doit inclure ce cas : client ad hoc avec
   l'identifiant de la CLI.
2. **Boucle de relance launchd.** Avec `KeepAlive = true`, un daemon qui
   « refuse de démarrer » quand les permissions sont mauvaises est relancé
   toutes les 10 s, indéfiniment. Proposition : il reste vivant, ne lance
   aucun tunnel, journalise l'erreur et l'expose via `status()` pour que
   l'app et la CLI l'affichent.
3. **Premier démarrage.** Au départ, aucun fichier root n'existe et l'app
   (non root) ne peut pas les créer. Le daemon crée
   `/Library/Application Support/Skluz/` (755), `keys/` (700) et un
   `tunnels.json` vide (600, `root:wheel`). Il ne refuse que des éléments
   **existants** mal protégés : mauvais propriétaire, lisibles par le groupe
   ou les autres, ou liens symboliques.
4. **Autorisation des appels de mutation.** La signature de code authentifie
   le *programme* client, pas l'*utilisateur*. N'importe quel compte local
   peut lancer Skluz.app et créer un tunnel exécuté en root. Proposition :
   réserver `upsertTunnel`, `deleteTunnel`, `setEnabled`, `generateKey`,
   `importKey` et `trustHostKey` aux UID du groupe `admin`
   (`NSXPCConnection.effectiveUserIdentifier`) ; `version`, `status` et
   `listTunnels` restent ouverts.
5. **Backoff du daemon.** Le plan ne dit pas si le daemon abandonne. Un
   service sans session ne doit jamais abandonner : plafond à 60 s,
   tentatives illimitées, remise à zéro au retour réseau (`NWPathMonitor`).

Points mineurs à intégrer en cours de route :

- Ajouter `-o GlobalKnownHostsFile=/dev/null` : `-F /dev/null` n'empêche pas
  la lecture de `/etc/ssh/ssh_known_hosts`.
- `fetchHostKey(host:port:)` doit passer par la même validation host/port
  que `SSHCommandBuilder` avant d'appeler `ssh-keyscan`.
- `SMAppService.daemon` est lié à l'emplacement de l'app : déplacer
  Skluz.app après l'enregistrement casse le daemon.

## 9. Décisions validées par Sébastien (2026-10-12)

Toutes intégrées à [`PLAN_SKLUZD.md`](PLAN_SKLUZD.md) et à `CLAUDE.md`.

- **D1. Autorité des documents** — validée. `PLAN_SKLUZD.md` fait autorité
  pour le mode Système ; `PLAN_SKLUZ.md` reste la référence du mode Session.
  Les invariants de `CLAUDE.md` sont répartis en trois blocs : Commun /
  Session / Système. Le stockage de clés sans passphrase par le daemon est un
  compromis assumé, compensé par les droits root et la restriction
  `authorized_keys`.
- **D2. Modèle et builder** — validée. Modèle unique `TunnelConfig` avec
  `mode` ; il garde les champs Session (`type`, `proxyJump`, `extraArgs`,
  `autoStart`, `autoRestart`) et ajoute `localBindAddress` et `keyRef`
  (enum `.path` / `.managed`). `sshHost`/`sshUser`/`sshPort` deviennent
  `host`/`user`/`port`. Validation commune, puis deux politiques :
  - Session : arguments identiques à aujourd'hui ; `localBindAddress` vide
    garde l'écoute IPv4 + IPv6 ;
  - Système : liste blanche, `user` obligatoire (sinon `root`), `-L`
    uniquement.

  Une source de vérité par mode. Migration `tunnels.json` v1 → v2 avec
  sauvegarde `tunnels.v1.json` ; Skluz 1.0 ne relit pas un fichier v2.
- **D3. Reconnexion** — validée.
  - Système : exponentiel 1 → 60 s, jitter ±20 %, jamais d'abandon, et
    `NWPathMonitor` (relance immédiate au retour du réseau, redémarrage sur
    changement d'interface, anti-rebond 2 s).
  - Session : table 2/5/15/30/60 s et 5 tentatives inchangées.
  - Dans les deux modes, le compteur n'est remis à zéro qu'après 30 s
    stables. Aujourd'hui, la remise à zéro à 500 ms fait réessayer
    indéfiniment toutes les 2 s un ssh qui échoue lentement.
- **D4. Corrections du plan** — validées toutes les quatre : requirement XPC
  parenthésée (§8.1), pas de boucle launchd (§8.2), création des fichiers au
  premier démarrage et refus des liens symboliques (§8.3), mutations
  réservées au groupe `admin` (§8.4). La §8.5 est couverte par D3.
- **D5. Bug `autoStart`** — corrigé tout de suite, dans un commit séparé
  avant la phase 1.
- **D6. Prérequis Mac mini** — validée. `DaemonManager` refuse l'activation
  hors de `/Applications/Skluz.app`. L'approbation initiale exige une session
  graphique unique (VNC). Le compte qui pilote Skluz doit être admin.
