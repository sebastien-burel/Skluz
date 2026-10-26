# PLAN_SKLUZD — Tunnels Skluz sans session ouverte

## Contexte et objectif

Le Mac mini (macOS 27, Apple Silicon, FileVault actif) est déverrouillé par SSH au démarrage, mais **aucune session graphique ne s'ouvre**. Skluz (`net.haruni.skluz`, app de barre de menus, Team ID `82FW35VV68`) ne démarre donc pas et les tunnels SSH restent fermés tant que personne ne se connecte par VNC.

**Objectif** : ajouter à Skluz un daemon système `skluzd`, embarqué dans le bundle et enregistré via `SMAppService.daemon`. Ce daemon ouvre et supervise les tunnels marqués « système » dès le déverrouillage du disque, sans session. L'app de barre de menus devient l'interface de pilotage du daemon et conserve son mode actuel pour les tunnels « session ».

**Critère de succès global** : après `sudo reboot` et un déverrouillage FileVault par SSH, **sans connexion VNC**, `skluz status` affiche tous les tunnels système à l'état `up` en moins de 60 s.

## Architecture cible

```
Skluz.app/
└── Contents/
    ├── MacOS/
    │   ├── Skluz            ← app barre de menus (UI, client XPC)
    │   └── skluzd           ← daemon headless (root, launchd)
    ├── Helpers/
    │   └── skluz            ← CLI de statut (client XPC) — pas dans MacOS/ : sur un volume
    │                          insensible à la casse, « skluz » écraserait l'app « Skluz »
    └── Library/LaunchDaemons/
        └── net.haruni.skluzd.plist   (BundleProgram, MachServices, KeepAlive)

/Library/Application Support/Skluz/      (root:wheel 755)
├── tunnels.json             (root:wheel 600) ← config des tunnels système
├── keys/                    (root:wheel 700) ← clés dédiées, 600
└── known_hosts              (root:wheel 644)
```

- **SkluzCore** (Swift package local) : modèle `TunnelConfig`, constructeur de commande `ssh` sur liste blanche, `TunnelSupervisor`. Partagé par l'app, le daemon et la CLI.
- **IPC** : XPC Mach service `net.haruni.skluzd.xpc` (`NSXPCConnection`), avec exigence de signature de code côté daemon.
- **Logs** : `os.Logger`, subsystem `net.haruni.skluzd`.

## Contraintes de sécurité (non négociables)

1. Le daemon tourne en **root** et lance `/usr/bin/ssh`. Toute option `ssh` arbitraire venue de l'IPC permettrait d'exécuter du code en root. Les options `ProxyCommand`, `LocalCommand`, `PermitLocalCommand`, `KnownHostsCommand`, `Match exec` et `-o` libres sont donc **interdites**. La commande est construite uniquement à partir des champs typés de `TunnelConfig`.
2. Le daemon n'accepte que les clients XPC signés par l'équipe `82FW35VV68` avec l'identifiant `net.haruni.skluz` ou `net.haruni.skluz.cli` (`setCodeSigningRequirement`, requirement exacte en phase 4 : les identifiants sont **entre parenthèses**, cf. audit §8.1).
3. Chaque `ssh` est lancé avec : `-N -T -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/Library/Application Support/Skluz/known_hosts -o GlobalKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -o IdentityFile="<clé dédiée>"`. `user` est obligatoire : sans config ssh, ssh utiliserait `root`.
   - Les chemins de `UserKnownHostsFile` et `IdentityFile` sont **entre guillemets** : ssh coupe ces valeurs sur les espaces, et `/Library/Application Support/…` deviendrait deux fichiers inexistants (vérifié en phase 1 : « Host key verification failed » systématique).
   - La clé passe par `-o IdentityFile`, **jamais par `-i`** : ssh ignore silencieusement un `-i` vers un fichier absent et se rabat sur les clés par défaut du processus, donc celles de root (vérifié avec `ssh -G`).
4. Les clés du daemon **n'ont pas de passphrase**, puisque le trousseau de session est verrouillé avant connexion. En compensation, elles sont dédiées aux tunnels et restreintes côté serveur (voir phase 5).
5. Les ports d'écoute locaux sont liés à `127.0.0.1` par défaut. L'écoute sur une autre interface exige un champ explicite dans la config.
6. Les appels XPC qui modifient l'état (`upsertTunnel`, `deleteTunnel`, `setEnabled`, `generateKey`, `importKey`, `trustHostKey`) ou qui font agir root sur le réseau (`fetchHostKey`, un seul à la fois) sont réservés aux utilisateurs du groupe `admin` (`effectiveUserIdentifier` de la connexion). La lecture (`version`, `status`, `listTunnels`, `listKeys`) reste ouverte.
7. Le daemon refuse tout élément de `/Library/Application Support/Skluz/` qui n'appartient pas à root, a des droits trop larges ou est un lien symbolique (`lstat`).

> **Décisions validées par Sébastien le 2026-10-12** (D1 à D6, détail dans
> [`AUDIT_SKLUZ.md`](AUDIT_SKLUZ.md) §9) : elles sont intégrées ci-dessous.
> Ce plan fait autorité pour le mode Système ; `PLAN_SKLUZ.md` reste la
> référence du mode Session.

---

## Phase 0 — Audit du code existant (aucune modification)

**Tâches**
- Lire le dépôt Skluz et produire `docs/AUDIT_SKLUZ.md` couvrant :
  - comment les tunnels sont lancés (`Process` + `/usr/bin/ssh` ? libssh ? NIO SSH ?) et avec quelles options ;
  - où et comment la config est stockée (UserDefaults, JSON, trousseau) ;
  - la gestion des clés et passphrases (trousseau, `ssh-agent`, `~/.ssh`) ;
  - la supervision et la reconnexion actuelles ;
  - la cible de déploiement, l'état du sandbox, la signature et la notarisation ;
  - le mécanisme de lancement à l'ouverture de session (`SMAppService.mainApp` ?).
- Lister les écarts avec l'architecture cible et signaler les points bloquants. En particulier : si l'app est sandboxée, vérifier que l'enregistrement d'un daemon via `SMAppService` reste possible, ou proposer de retirer le sandbox.

**PASS** : `AUDIT_SKLUZ.md` existe, répond à chaque point et liste les décisions à valider par Sébastien. Le code est inchangé (`git diff` vide hors `docs/`).
**FAIL** : un point est laissé sans réponse ou du code a été modifié.

> ⏸ Arrêt : validation de l'audit par Sébastien avant la phase 1.

## Phase 1 — Extraction de SkluzCore

**Tâches**
- Créer le package local `SkluzCore` avec :
  - `TunnelConfig : Codable, Sendable, Identifiable` (D2), modèle unique pour les deux modes :
    - communs : `id`, `name`, `mode` (`.session` / `.system`), `enabled`, `type`, `host`, `port?`, `user?`, `localBindAddress?`, `localPort`, `remoteHost?`, `remotePort?`, `keyRef?` (enum `.path(String)` / `.managed(name)`) ;
    - réservés au mode Session : `proxyJump`, `extraArgs`, `autoStart`, `autoRestart` ;
    - `host`/`user`/`port` remplacent `sshHost`/`sshUser`/`sshPort` ;
  - `SSHCommandBuilder` (`throws`) : validation commune aux deux modes (host et remoteHost `[A-Za-z0-9._:-]`, user `[A-Za-z0-9._-]`, sans `-` initial ; ports 1–65535 ; aucun caractère de contrôle, `name` compris), puis deux politiques :
    - **Session** : arguments identiques à aujourd'hui (mêmes options, même ordre, `extraArgs` en dernier) ; `localBindAddress` vide = pas d'adresse dans `-L` ;
    - **Système** : liste blanche des contraintes ci-dessus ; `type == .localForward`, `user` et `keyRef = .managed` obligatoires ; `proxyJump`/`extraArgs` non vides refusés ; bind `127.0.0.1` par défaut ; nom de clé `[A-Za-z0-9_-]` ;
  - `TunnelSupervisor` (actor) avec une politique de relance par mode (D3) :
    - **Session** : si `autoRestart`, délais 2/5/15/30/60 s, abandon après 5 échecs ;
    - **Système** : toujours, exponentiel 1 → 60 s, jitter ±20 %, jamais d'abandon ; `NWPathMonitor` (anti-rebond 2 s) : relance immédiate et remise à zéro au retour du réseau, redémarrage des tunnels actifs sur changement d'interface ;
    - dans les deux modes, le compteur d'échecs n'est remis à zéro qu'après **30 s** de fonctionnement stable (au lieu de 500 ms aujourd'hui, ce qui empêchait d'atteindre la limite de 5) ;
    - horloge et aléa injectables pour les tests ; expose un `AsyncStream<TunnelState>`.
- Migration du `tunnels.json` utilisateur v1 → v2 au chargement (`mode = .session`, `identityFile` → `.path`), avec une copie `tunnels.v1.json` avant la première réécriture.
- Faire migrer l'app vers SkluzCore **sans changement de comportement visible**, hors remise à zéro du compteur après 30 s (validée).

**PASS**
- Les tests existants de `SSHCommandBuilderTests` passent avec les mêmes tableaux d'arguments attendus (seuls les noms de champs changent).
- Tests unitaires `SSHCommandBuilder` : cas nominal Système, et rejet de `host = "-oProxyCommand=…"`, `user` contenant `;` ou un saut de ligne, port 0 ou 70000, bind sur `0.0.0.0` sans opt-in, `extraArgs` ou `proxyJump` en Système, Système sans `user`.
- Tests `TunnelSupervisor` avec un faux `ssh` (script qui se termine) : la relance suit le backoff attendu dans chaque mode, et le compteur ne repart à zéro qu'après 30 s stables.
- Test de migration : un fichier v1 est relu à l'identique en v2, et la sauvegarde v1 existe.
- L'app existante ouvre ses tunnels comme avant (test manuel : `lsof -nP -iTCP -sTCP:LISTEN | grep ssh`).

**FAIL** : un test échoue, ou une régression apparaît dans l'app.

## Phase 2 — Daemon `skluzd` en exécution manuelle

**Tâches**
- Nouveau target exécutable `skluzd` (hardened runtime, signé Team `82FW35VV68`), lié à SkluzCore.
- Au démarrage, il crée les éléments absents : `/Library/Application Support/Skluz/` (`755`), `keys/` (`700`), `tunnels.json` vide `{ "version": 2, "tunnels": [] }` (`600`) et `known_hosts` vide (`644`), tous `root:wheel`.
- Il lit `/Library/Application Support/Skluz/tunnels.json`. Si un élément existant n'appartient pas à root, a des droits trop larges ou est un lien symbolique, il **reste vivant** (pas de boucle de relance launchd) mais ne lance aucun tunnel, journalise l'erreur une fois, et l'expose (avec la commande de correction) via `status()` en phase 4. Il ne corrige jamais les permissions lui-même.
- Il supervise tous les tunnels `mode == .system && enabled`.
- Il gère `SIGTERM` proprement (ferme les `ssh` enfants, sans processus orphelin) et recharge la config sur `SIGHUP`.
- Il écrit ses logs via `os.Logger` (subsystem `net.haruni.skluzd`, catégories `supervisor`, `xpc`, `config`).

**PASS** (en lançant `sudo …/skluzd`)
- Les tunnels de test sont à l'écoute en moins de 10 s.
- Après `sudo kill <pid ssh>`, le tunnel revient en moins de 15 s.
- En coupant puis rétablissant le Wi-Fi ou Ethernet, le tunnel revient en moins de 30 s après le retour réseau.
- Après `SIGTERM`, `pgrep -f "ssh .*-N"` ne renvoie plus rien.
- Au premier lancement sur une machine vierge, le dossier et les fichiers sont créés avec les droits attendus.
- Si `tunnels.json` est en `644` (ou est un lien symbolique), le daemon reste vivant, ne lance aucun tunnel et affiche un message explicite dans `log show`.

**FAIL** : un seul de ces points n'est pas vérifié.

## Phase 3 — Intégration launchd via SMAppService

**Tâches**
- Créer `net.haruni.skluzd.plist` dans `Contents/Library/LaunchDaemons/`, avec :
  - `Label` = `net.haruni.skluzd` ;
  - `BundleProgram` = `Contents/MacOS/skluzd` ;
  - `MachServices` = `{ net.haruni.skluzd.xpc = true }` ;
  - `RunAtLoad` = true ;
  - `KeepAlive` = true ;
  - `AssociatedBundleIdentifiers` = `[net.haruni.skluz]`.
- Phases de build Copy Files : `skluzd` vers `Contents/MacOS`, le plist vers `Contents/Library/LaunchDaemons`.
- Dans l'app, ajouter un service `DaemonManager` qui gère `SMAppService.daemon(plistName:)` : `register()`, `unregister()` et la lecture du `status`. Quand le statut vaut `.requiresApproval`, il appelle `SMAppService.openSystemSettingsLoginItems()` et affiche une explication à l'utilisateur.
- `DaemonManager` refuse `register()` si l'app ne tourne pas depuis `/Applications/Skluz.app` (D6 : DMG monté, Téléchargements, App Translocation ou `~/Applications`), avec le message « Déplacez Skluz dans le dossier Applications, puis relancez-le. »
- L'approbation dans Réglages Système exige une session graphique **une seule fois**, à l'installation (VNC sur le Mac mini) ; ensuite plus aucune session n'est nécessaire.

**PASS**
- Lancée hors de `/Applications`, l'app refuse l'activation avec le message ci-dessus.
- Après enregistrement et approbation, `sudo launchctl print system/net.haruni.skluzd` affiche `state = running`.
- Après `sudo kill -9 <pid skluzd>`, launchd relance le daemon en moins de 10 s et les tunnels reviennent.
- `sudo sfltool dumpbtm` liste `skluzd` comme élément d'arrière-plan approuvé, rattaché à Skluz.

**FAIL** : le daemon n'est pas relancé, ou l'approbation n'est pas guidée dans l'UI.

## Phase 4 — API XPC et sécurité de l'IPC

**Tâches**
- Définir le protocole `SkluzDaemonProtocol` (`@objc`, types transportés en JSON `Data` pour rester simple) :
  - `version() -> String` ;
  - `listTunnels()`, `status()` (état, PID, dernière erreur, uptime, nombre de reconnexions par tunnel) ;
  - `upsertTunnel(_:)`, `deleteTunnel(id:)`, `setEnabled(id:, _:)` ;
  - `generateKey(name:) -> publicKey`, `importKey(name:, privateKey:)` ;
  - `fetchHostKey(host:, port:) -> fingerprints` et `trustHostKey(host:, port:, key:)`.
- Côté daemon, exiger une signature de code : `connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"82FW35VV68\" and (identifier \"net.haruni.skluz\" or identifier \"net.haruni.skluz.cli\")")`. Les **parenthèses sont obligatoires** : `and` est prioritaire sur `or`, et sans elles tout binaire ad hoc déclarant `net.haruni.skluz.cli` serait accepté. Les builds Debug passent aussi (le certificat Apple Development porte `OU=82FW35VV68`).
- Les appels de mutation et `fetchHostKey` vérifient que `effectiveUserIdentifier` appartient au groupe `admin` ; `version`, `status`, `listTunnels` et `listKeys` restent ouverts.
- `status()` expose aussi l'erreur de configuration globale du daemon (cf. phase 2).
- Toute écriture de config passe par `SSHCommandBuilder` pour validation **avant** d'être persistée, puis le fichier est écrit de façon atomique. `fetchHostKey` applique la même validation host/port avant `ssh-keyscan`.

**PASS**
- Un client XPC de test non signé, ou signé ad hoc, est rejeté — y compris un client ad hoc signé avec `-i net.haruni.skluz.cli`.
- Un appel de mutation depuis un compte non admin est refusé ; `status()` fonctionne depuis ce compte.
- `upsertTunnel` avec `host = "-oProxyCommand=touch /tmp/pwn"` est refusé, et `/tmp/pwn` n'existe pas.
- Un `upsertTunnel` valide fait apparaître le tunnel sans redémarrer le daemon.
- `tunnels.json` reste `root:wheel 600` après toutes les opérations.

**FAIL** : un client non autorisé est accepté, ou une injection d'options aboutit.

## Phase 5 — Clés dédiées et clés d'hôte

**Tâches**
- `generateKey` : le daemon exécute `ssh-keygen -t ed25519 -N "" -C "skluzd@<hostname>" -f keys/<name>`, avec des permissions `600` root, et renvoie la clé publique.
- Dans l'app, afficher la clé publique avec la ligne `authorized_keys` **restreinte** recommandée, prête à copier :
  `restrict,port-forwarding,permitopen="<remoteHost>:<remotePort>",command="/bin/false" ssh-ed25519 AAAA… skluzd@macmini`
- `importKey` : accepter une clé existante uniquement si elle n'a pas de passphrase (vérification par `ssh-keygen -y -P "" -f`). Sinon, refus avec un message expliquant pourquoi.
- Premier contact avec un hôte : le daemon lance `ssh-keyscan`, l'app affiche les empreintes SHA256 et l'utilisateur confirme. Le daemon ajoute alors l'entrée à son `known_hosts`. Jamais de `StrictHostKeyChecking=accept-new`.

**PASS**
- Une clé générée est en `600 root:wheel`. Une clé avec passphrase est refusée à l'import.
- Une connexion vers un hôte absent de `known_hosts` échoue avec l'état `hostKeyUnknown`, et non une acceptation silencieuse.
- Avec la ligne `restrict,permitopen=…,command="/bin/false"` côté serveur, le tunnel fonctionne, mais `ssh -i <clé> host 'id'` n'exécute rien. Sans `command=`, `restrict` ne bloque que le pty : **une commande passée à ssh s'exécuterait** (bug du plan initial, vérifié en phase 5).

**FAIL** : une clé est stockée avec des permissions plus larges, ou une clé d'hôte est acceptée sans confirmation.

## Phase 6 — UI de l'app de barre de menus

**Tâches**
- Pour chaque tunnel, un sélecteur de mode **Session / Système (sans ouverture de session)**. Le passage en Système guide l'utilisateur : choix ou génération de la clé dédiée, confirmation de la clé d'hôte, puis envoi au daemon.
- Une section « Service système » affichant le statut `SMAppService`, la version du daemon comparée à celle de l'app, et les boutons Activer, Désactiver et Ouvrir les réglages.
- Le menu affiche l'état des tunnels système en temps réel (polling `status()` toutes les 5 s, ou notifications XPC si c'est simple à faire).
- Un assistant de migration : il liste les tunnels existants et propose de passer en Système ceux qui doivent survivre à un redémarrage.
- Les tunnels en mode Session continuent de fonctionner exactement comme aujourd'hui.

**PASS** : un tunnel peut passer de Session à Système de bout en bout depuis l'UI, sans terminal. Les états affichés correspondent à `skluz status`. Aucune régression sur les tunnels Session.
**FAIL** : une étape oblige à passer par le terminal, ou un état affiché est faux.

## Phase 7 — CLI `skluz` pour le contrôle par SSH

**Tâches**
- Target `skluz` (identifiant `net.haruni.skluz.cli`), client XPC, avec trois commandes :
  - `skluz status` : tableau `nom | mode | état | port local | uptime | reconnexions | dernière erreur` ;
  - `skluz status --json` ;
  - `skluz check` : code de sortie `0` si tous les tunnels système activés sont `up`, `1` sinon. Utilisable dans `~/bin/check-services.sh`.
- À l'activation du service, l'app propose d'installer un lien symbolique `/usr/local/bin/skluz`.

**PASS** : `skluz status` fonctionne en SSH **sans session ouverte**. `skluz check` renvoie `1` quand un tunnel est coupé volontairement.
**FAIL** : la CLI exige une session graphique ou renvoie un code de sortie incorrect.

## Phase 8 — Validation au redémarrage, mise à jour et désinstallation

**Tâches**
- Mise à jour : au lancement, l'app compare `version()` du daemon à sa propre version. En cas d'écart, elle fait `unregister()` puis `register()`, ou demande au daemon de se terminer pour que launchd relance le nouveau binaire.
- Désinstallation : un bouton « Supprimer le service système » fait `unregister()`. Une option supprime aussi `/Library/Application Support/Skluz/` après confirmation.
- Détecter pendant qu'un tunnel tourne les refus de redirection du serveur (`open failed: administratively prohibited` sur stderr, `permitopen` qui ne correspond pas ou service absent côté serveur) : le tunnel est « up » mais ne transporte rien. L'exposer dans `status()`, le menu et `skluz status` avec un message actionnable (constaté en phase 6).
- Ajouter à `docs/` une page `SKLUZD.md` (commandes `log` à écrire `/usr/bin/log` : sous zsh, `log` est une commande interne ; piège constaté en phase 4 : si LaunchServices connaît d'autres copies de Skluz — Corbeille, builds —, l'activation peut échouer en « Operation not permitted » ; corriger avec `lsregister -u` sur les copies parasites puis `lsregister -f /Applications/Skluz.app`) : fonctionnement, prérequis d'installation (Skluz dans `/Applications`, compte admin, une session VNC unique pour l'approbation initiale, déverrouillage FileVault par SSH), emplacements des fichiers, commandes de diagnostic (`skluz status`, `sudo launchctl print system/net.haruni.skluzd`, `log show --last boot --predicate 'subsystem == "net.haruni.skluzd"'`).

**PASS — test de référence sur le Mac mini**
1. FileVault actif, au moins 2 tunnels en mode Système.
2. `sudo reboot`.
3. Déverrouillage FileVault par SSH, **sans aucune connexion VNC**.
4. En moins de 60 s : `skluz check` renvoie `0` et `sudo lsof -nP -iTCP -sTCP:LISTEN | grep ssh` liste les ports attendus (sans `sudo`, `lsof` ne montre pas les ssh de root).
5. `who | grep console` est vide, ce qui confirme qu'aucune session n'est ouverte.
6. Après installation d'une version N+1 de l'app, `skluz status` reporte la nouvelle version du daemon sans redémarrage du Mac.
7. Après désactivation du service, `launchctl print system/net.haruni.skluzd` échoue et plus aucun `ssh` du daemon ne tourne.

**FAIL** : un seul de ces points échoue.

---

## Hors périmètre

- Remplacer `/usr/bin/ssh` par une implémentation SSH embarquée.
- Gérer des tunnels dynamiques (`-D`) ou inverses (`-R`). À ajouter plus tard via des champs typés dédiés, jamais via des options libres.
- Distribuer le daemon à des tiers. La notarisation reste recommandée, mais n'est pas un critère de ce plan.
