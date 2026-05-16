# Plan d'implémentation — Skluz (Gestionnaire de tunnels SSH macOS)

> **Pour Claude Code** : ce document est le plan complet de l'application. Suis-le phase par phase, valide chaque phase avant de passer à la suivante. Pose des questions si quelque chose est ambigu plutôt que d'inventer.

> **Étymologie** : *Skluz* est le mot breton pour "écluse". Métaphore juste pour un gestionnaire de tunnels SSH : on contrôle le passage, on ouvre, on ferme, on arbitre les flux.

---

## 1. Vue d'ensemble

**Nom du projet** : `Skluz`
**Éditeur** : Haruni SAS
**Bundle ID** : `net.haruni.skluz`
**Plateforme** : macOS 26.5+ (Tahoe minimum)
**Langage** : Swift 6 (strict concurrency)
**UI** : SwiftUI + AppKit (NSStatusItem pour la menubar)
**Type d'app** : Menu bar app (LSUIElement = YES, pas d'icône Dock, pas de fenêtre principale)
**Lancement** : Auto-démarrage à la connexion utilisateur via `SMAppService` (ServiceManagement)
**Distribution** : Binaire local signé Developer ID (pas App Store → permet `Process` + sandbox désactivé)

### Comportement principal

- Icône dans la menubar (écluse stylisée ou SF Symbol fallback) avec badge couleur selon l'état.
- Clic gauche → popover SwiftUI avec liste des tunnels (état, start/stop, edit).
- Clic droit ou menu déroulant → préférences, ajout rapide, quitter.
- Chaque tunnel est un `Process` qui lance `/usr/bin/ssh` avec les bons arguments.
- État persisté en JSON dans `~/Library/Application Support/Skluz/`.
- Logs par tunnel (stderr capturé) consultables depuis l'UI.

### Fonctionnalités cibles (v1)

- Ajouter / éditer / supprimer un tunnel.
- Types supportés : `-L` (local), `-R` (remote), `-D` (SOCKS dynamique).
- Authentification : clés SSH uniquement, via agent SSH système. Pas de mot de passe.
- Support de `~/.ssh/config` : si le host renseigné existe dans le config, on l'utilise tel quel (pas besoin de redéfinir port/user/identityfile).
- Option ProxyJump (`-J`) pour multi-hop, en champ texte libre.
- Auto-restart en cas de coupure (option par tunnel, désactivée par défaut).
- Démarrage automatique du tunnel au lancement de l'app (option par tunnel).
- Launch at Login via `SMAppService` toggleable depuis les préférences.

### Non-objectifs (v1)

- Pas de support password (l'utilisateur s'appuie sur clés + agent).
- Pas de gestion `known_hosts` custom (on délègue à OpenSSH).
- Pas de stockage de credentials dans Keychain.
- Pas d'éditeur de `~/.ssh/config` (on lit, on ne modifie pas).
- Pas de sandboxing App Store.

---

## 2. Architecture

```
Skluz/
├── SkluzApp.swift                    # @main, AppDelegate, SMAppService
├── App/
│   ├── AppDelegate.swift             # NSApplicationDelegate, setup menubar
│   ├── MenuBarController.swift       # NSStatusItem, gestion popover
│   └── LaunchAtLoginManager.swift    # SMAppService wrapper
├── Models/
│   ├── Tunnel.swift                  # struct Tunnel: Codable, Identifiable
│   ├── TunnelType.swift              # enum: localForward, remoteForward, dynamic
│   └── TunnelState.swift             # enum: stopped, starting, running, failed, reconnecting
├── Services/
│   ├── TunnelStore.swift             # actor — persistance JSON + état en mémoire
│   ├── TunnelRunner.swift            # actor — gestion Process par tunnel
│   ├── SSHConfigParser.swift         # lecture passive de ~/.ssh/config
│   └── LogStore.swift                # actor — buffer circulaire de logs par tunnel
├── Views/
│   ├── MenuBarPopoverView.swift      # liste des tunnels, état, actions
│   ├── TunnelRowView.swift           # une ligne tunnel
│   ├── TunnelEditorView.swift        # formulaire ajout/édition
│   ├── PreferencesView.swift         # launch at login, options globales
│   └── LogViewerView.swift           # consultation logs d'un tunnel
└── Resources/
    ├── Info.plist                    # LSUIElement = YES
    ├── Skluz.entitlements            # pas de sandbox
    ├── AppIcon.icns                  # icône d'app
    └── MenuBarIcon.pdf               # icône menubar (template image)
```

### Choix de concurrence

- `TunnelStore` et `TunnelRunner` sont des **actors** Swift 6.
- Les `Process` SSH tournent en arrière-plan, leurs callbacks (terminationHandler, pipe handlers) sont marshallés vers l'actor via `Task`.
- L'UI observe l'état via `@Observable` (Swift 6 macros) — pas de Combine.

---

## 3. Identité visuelle

### Nom affiché

- Nom de l'app : **Skluz**
- Sous-titre dans le popover (en petit, optionnel) : *"SSH tunnels, by Haruni"*
- Copyright : `© 2026 Haruni SAS`

### Icône menubar

Concept : une écluse stylisée minimaliste.

**Design suggéré** (template image PDF monochrome, 22×22 pt) :
- Deux traits verticaux courts (les portes de l'écluse).
- Un trait horizontal qui les traverse au centre (le passage / le flux d'eau).
- Variante "running" : trait horizontal plus épais ou ondulé.
- Variante "failed" : trait horizontal interrompu / barré.

Fallback en attendant le design custom : `SF Symbol "arrow.left.arrow.right.square"` (vérifié sur SF Symbols 7 / macOS 26.5) ou `"network"` en template mode.

### Icône d'app (.icns)

À produire en phase 10. Variante plus riche de l'icône menubar : écluse stylisée avec un peu de profondeur, palette Haruni si possible (terracotta #E85D3A en accent, paper #FAF8F6 en fond, ink #2D2420 en trait).

### Badge d'état dans la menubar

- **Tous tunnels stoppés** : icône normale (template noire/blanche selon le thème système).
- **Au moins 1 tunnel running** : pastille verte discrète en superposition.
- **Au moins 1 tunnel failed** : pastille rouge en superposition (priorité sur le vert).
- **Reconnecting** : pastille orange clignotante (animation 1Hz).

---

## 4. Modèle de données

### `Tunnel`

```swift
struct Tunnel: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String                    // libellé affiché
    var type: TunnelType                // .localForward / .remoteForward / .dynamic
    var sshHost: String                 // hostname OU alias ~/.ssh/config
    var sshUser: String?                // nil si défini dans ~/.ssh/config
    var sshPort: Int?                   // nil = 22 ou via ~/.ssh/config
    var localPort: Int                  // port local d'écoute
    var remoteHost: String?             // pour -L / -R, nil pour -D
    var remotePort: Int?                // pour -L / -R, nil pour -D
    var proxyJump: String?              // option -J, ex: "bastion.example.com"
    var extraArgs: [String]             // args ssh additionnels libres (avancé)
    var autoStart: Bool                 // démarrer au lancement de l'app
    var autoRestart: Bool               // relancer si le process meurt
    var enabled: Bool                   // tunnel activé (sinon masqué/ignoré)
}
```

### `TunnelType`

```swift
enum TunnelType: String, Codable, CaseIterable, Sendable {
    case localForward      // -L localPort:remoteHost:remotePort user@host
    case remoteForward     // -R localPort:remoteHost:remotePort user@host
    case dynamic           // -D localPort user@host (SOCKS proxy)
}
```

### `TunnelState`

```swift
enum TunnelState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32, since: Date)
    case failed(reason: String, at: Date)
    case reconnecting(attempt: Int)
}
```

### Persistance

- Fichier : `~/Library/Application Support/Skluz/tunnels.json`
- Format : `{ "version": 1, "tunnels": [...] }`
- Écriture atomique (write to temp + rename).
- Migration de schéma préparée via le champ `version`.

---

## 5. Construction de la commande SSH

`TunnelRunner` doit construire les arguments du process SSH ainsi :

```
/usr/bin/ssh
  -N                          # pas de commande distante
  -T                          # pas de pty
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o ExitOnForwardFailure=yes
  -o StrictHostKeyChecking=accept-new
  [-p <sshPort>]              # si sshPort est défini
  [-J <proxyJump>]            # si proxyJump est défini
  <forward-flag>              # -L / -R / -D selon le type
  [<user>@]<sshHost>
  [<extraArgs>...]
```

**Forward flag selon le type :**

- `.localForward` → `-L <localPort>:<remoteHost>:<remotePort>`
- `.remoteForward` → `-R <localPort>:<remoteHost>:<remotePort>`
- `.dynamic` → `-D <localPort>`

**Important :**

- Toujours utiliser `/usr/bin/ssh` (chemin absolu), pas de résolution PATH.
- `ExitOnForwardFailure=yes` est crucial : si le port local est déjà pris, ssh sort en erreur immédiatement plutôt que de rester zombie.
- `StrictHostKeyChecking=accept-new` : on accepte les nouveaux hosts mais on refuse si la clé change (équilibre sécurité/ergonomie).
- Ne **jamais** désactiver host key checking par défaut. C'est une option avancée à n'exposer qu'en `extraArgs` à l'utilisateur, avec un warning.

---

## 6. Cycle de vie d'un tunnel (`TunnelRunner`)

L'actor `TunnelRunner` gère un dictionnaire `[UUID: RunningTunnel]` où `RunningTunnel` contient le `Process`, les `Pipe` stdout/stderr, et l'état.

### Démarrage

1. Vérifier qu'aucun process n'est déjà en cours pour ce tunnel.
2. Construire les arguments (cf. §5).
3. Créer un `Process`, attacher des `Pipe` pour stdout/stderr, configurer `terminationHandler`.
4. Lancer via `process.run()` dans un do/catch.
5. Passer en état `.starting`, puis `.running` après ~500 ms si toujours vivant.
6. Lire stderr en continu et pousser dans `LogStore` (buffer circulaire, 1000 lignes max par tunnel).

### Arrêt

1. Envoyer `process.terminate()` (SIGTERM).
2. Attendre jusqu'à 3 secondes.
3. Si toujours vivant, `process.interrupt()` (SIGINT), puis SIGKILL en dernier recours via `kill(pid, SIGKILL)`.
4. Passer en `.stopped`.

### Auto-restart

- Si `tunnel.autoRestart` et `terminationHandler` est appelé avec exitCode != 0 et que l'arrêt n'a pas été demandé par l'utilisateur :
  - Passer en `.reconnecting(attempt: N)`.
  - Backoff exponentiel : 2s, 5s, 15s, 30s, 60s (plafonné).
  - Stop après 5 tentatives consécutives → `.failed`.

### Arrêt propre à la sortie de l'app

- `applicationWillTerminate` : arrêter tous les tunnels actifs (parallèle, timeout 3s global).

---

## 7. Lecture passive de `~/.ssh/config`

`SSHConfigParser` lit `~/.ssh/config` au démarrage et offre :

```swift
struct SSHConfigHost: Sendable {
    let aliasOrPattern: String
    let hostname: String?
    let user: String?
    let port: Int?
    let identityFile: String?
}

actor SSHConfigParser {
    func loadHosts() async -> [SSHConfigHost]
    func host(for alias: String) async -> SSHConfigHost?
}
```

**Usage dans l'UI** : dans le formulaire d'édition d'un tunnel, autocomplete le champ "host" avec les alias trouvés. Si l'utilisateur choisit un alias connu, les champs user/port sont préremplis et marqués "from ~/.ssh/config".

**Important** : on **ne réécrit jamais** `~/.ssh/config`. On le lit en lecture seule, point.

---

## 8. Menubar + popover

### `MenuBarController`

- `NSStatusItem` créé avec `NSStatusBar.system.statusItem(withLength: .variable)`.
- Icône custom template image (`MenuBarIcon.pdf`) avec template mode activé.
- Badge d'état superposé via Core Graphics ou variantes d'image (cf. §3).
- Clic → toggle un `NSPopover` qui contient `MenuBarPopoverView`.
- Le popover a `behavior = .transient` (se ferme au clic ailleurs).

### `MenuBarPopoverView`

Layout vertical :

```
┌──────────────────────────────────┐
│ Skluz                    ⚙️      │
├──────────────────────────────────┤
│ 🟢 prod-postgres   [Stop]  [✏️] │
│ ⚫ staging-redis   [Start] [✏️] │
│ 🔴 dev-bastion     [Start] [✏️] │  (failed, hover → tooltip raison)
├──────────────────────────────────┤
│ [+ Nouveau tunnel]               │
│ [Quitter Skluz]                  │
└──────────────────────────────────┘
```

Hauteur dynamique selon le nombre de tunnels (cap à ~500 pt, scroll si plus).

### `TunnelEditorView` (sheet)

Formulaire :

- Nom (texte)
- Type (segmented: Local / Remote / SOCKS)
- Host SSH (combobox avec autocomplete depuis `~/.ssh/config`)
- User (optionnel, désactivé si host vient de `~/.ssh/config`)
- Port SSH (optionnel)
- Port local (Int)
- Host distant + port distant (cachés pour SOCKS)
- ProxyJump (optionnel, repliable sous "Avancé")
- Args additionnels (optionnel, repliable, multi-ligne)
- Toggle "Démarrer au lancement"
- Toggle "Reconnexion automatique"
- Boutons : Annuler / Enregistrer / Tester

**Bouton "Tester"** : démarre le tunnel temporairement (10s max) et affiche le résultat (succès ou première ligne stderr).

---

## 9. Launch at Login

Utiliser `SMAppService.mainApp` (macOS 13+) :

```swift
import ServiceManagement

@MainActor
struct LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

Toggle exposé dans `PreferencesView`. Gérer le cas où l'utilisateur a désactivé l'app dans Réglages Système → Général → Ouverture (status `.requiresApproval`) en affichant un bouton qui ouvre directement ce panneau via `SMAppService.openSystemSettingsLoginItems()`.

---

## 10. Info.plist & entitlements

### `Info.plist`

```xml
<key>CFBundleName</key>
<string>Skluz</string>
<key>CFBundleDisplayName</key>
<string>Skluz</string>
<key>CFBundleIdentifier</key>
<string>net.haruni.skluz</string>
<key>LSUIElement</key>
<true/>
<key>LSMinimumSystemVersion</key>
<string>26.5</string>
<key>NSHumanReadableCopyright</key>
<string>© 2026 Haruni SAS. Skluz, ar skluz evit ho tunelloù SSH.</string>
```

### `Skluz.entitlements`

- `com.apple.security.app-sandbox` : **NON** (sandbox désactivé, l'app n'est pas destinée à l'App Store).
- Signature Developer ID Application.
- Hardened Runtime activé.
- Notarization recommandée pour distribution.

---

## 11. Phases d'implémentation

> **Pour Claude Code** : implémente une phase à la fois, fais valider visuellement avant de passer à la suivante. Chaque phase doit être compilable et testable.

### Phase 1 — Squelette projet
- Créer le projet Xcode `Skluz` (App macOS, SwiftUI, Swift 6).
- Bundle ID `net.haruni.skluz`, deployment target 26.5.
- Configurer `Info.plist` (LSUIElement = YES), entitlements.
- `AppDelegate` minimal qui crée un `NSStatusItem` avec SF Symbol fallback.
- Clic → log dans la console.
- ✅ Critère : l'app se lance, icône visible dans menubar, pas d'icône Dock.

### Phase 2 — Popover SwiftUI
- Créer `MenuBarPopoverView` avec contenu statique (liste hardcodée de 2-3 tunnels fake).
- Brancher l'ouverture du popover sur le clic de l'icône.
- Header "Skluz" + engrenage préférences (non fonctionnel pour l'instant).
- Style propre, dark/light mode.
- ✅ Critère : clic menubar → popover s'ouvre avec liste fake.

### Phase 3 — Modèle + persistance
- Implémenter `Tunnel`, `TunnelType`, `TunnelState`.
- Implémenter `TunnelStore` (actor) avec load/save JSON dans `~/Library/Application Support/Skluz/`.
- Charger au démarrage, persister à chaque modification.
- ✅ Critère : ajouter un tunnel via du code de test → le retrouver après relance.

### Phase 4 — Éditeur de tunnel
- Implémenter `TunnelEditorView` (sheet présentée depuis le popover).
- Validation des champs (port 1-65535, etc.).
- Sauvegarde via `TunnelStore`.
- Pas encore d'autocomplete `~/.ssh/config`.
- ✅ Critère : ajout/édition/suppression de tunnels fonctionnels, persistés.

### Phase 5 — TunnelRunner (cœur)
- Implémenter `TunnelRunner` (actor).
- Construction des arguments SSH (cf. §5).
- Démarrage/arrêt d'un tunnel via `Process`.
- Capture stderr → `LogStore`.
- Mise à jour `TunnelState` observable depuis l'UI.
- ✅ Critère : démarrer un tunnel `-L` réel vers un serveur SSH, vérifier qu'il forward bien le port, l'arrêter proprement.

### Phase 6 — Auto-restart + arrêt propre
- Implémenter backoff exponentiel sur `terminationHandler`.
- Arrêter tous les tunnels à `applicationWillTerminate`.
- ✅ Critère : couper la connexion réseau → tunnel passe en reconnecting → reprend quand le réseau revient.

### Phase 7 — Lecture ~/.ssh/config
- Implémenter `SSHConfigParser`.
- Autocomplete dans `TunnelEditorView`.
- ✅ Critère : si `~/.ssh/config` contient `Host monserveur`, il apparaît dans l'autocomplete.

### Phase 8 — Launch at Login + préférences
- Implémenter `LaunchAtLoginManager` avec `SMAppService`.
- `PreferencesView` accessible depuis le popover (engrenage).
- Toggle launch at login.
- ✅ Critère : activer le toggle, redémarrer la session macOS → l'app démarre seule.

### Phase 9 — Visionneuse de logs
- `LogViewerView` (fenêtre séparée ou sheet) listant les lignes stderr du tunnel.
- Bouton "Effacer", "Copier".
- ✅ Critère : démarrer un tunnel volontairement cassé (mauvais host) → voir le message d'erreur SSH dans les logs.

### Phase 10 — Polish + identité visuelle + packaging
- Bouton "Tester" dans l'éditeur.
- Tooltips, raccourcis clavier (⌘N nouveau tunnel, ⌘Q quitter).
- Icône menubar custom (écluse stylisée, template PDF).
- Icône d'app `AppIcon.icns` avec palette Haruni.
- Badges d'état (vert/rouge/orange) sur l'icône menubar.
- Signature Developer ID + notarization.
- ✅ Critère : `.app` distribuable, démarre proprement sur une autre machine.

---

## 12. Points de vigilance

- **Ne pas hardcoder de chemins absolus** sauf `/usr/bin/ssh`.
- **Toujours échapper les arguments** : `Process.arguments` les passe en tableau, pas de shell, donc pas de risque d'injection. Ne **jamais** construire une string puis la passer à `/bin/sh`.
- **Gestion du SIGPIPE** : les `Pipe` doivent être lus en continu sinon le child process peut bloquer. Utiliser `FileHandle.readabilityHandler` ou `bytes`.
- **Mémoire des logs** : buffer circulaire obligatoire, sinon un tunnel verbeux pendant des jours bouffe toute la RAM.
- **Conflits de port local** : détecter le cas où `ExitOnForwardFailure` fait sortir ssh avec exit code 255 dans la première seconde, afficher un message clair (« port 5432 déjà utilisé »).
- **Swift 6 strict concurrency** : tous les types passés entre actor et MainActor doivent être `Sendable`. Si tu galères, marque les modèles `Sendable` explicitement.
- **Tests** : écris au minimum un test unitaire sur la construction des arguments SSH (donner un `Tunnel`, vérifier le tableau d'args attendu). Test critique car c'est là que les régressions silencieuses se cachent.

---

## 13. Extensions futures (post-v1, ne pas implémenter maintenant)

- Groupes de tunnels (démarrer/arrêter en lot).
- Import/export de configuration (JSON ou format `~/.ssh/config` partiel).
- Notifications macOS sur changement d'état.
- Statistiques (uptime, bytes transférés via `lsof` ou `nettop`).
- Détection automatique d'un changement de réseau (Wi-Fi) → reconnect.
- Mode "wake from sleep" → reconnect.
- Support keychain pour passphrases si on veut éviter d'ouvrir l'agent SSH au login.
- Localisation : interface en breton (`br`) en plus de FR/EN, clin d'œil au nom.

---

## 14. Référence rapide — commandes SSH générées

| Cas | Commande |
|-----|----------|
| Local forward simple | `ssh -N -T -o ... -L 5432:db.internal:5432 user@bastion.example.com` |
| Remote forward | `ssh -N -T -o ... -R 8080:localhost:8080 user@public.example.com` |
| SOCKS dynamique | `ssh -N -T -o ... -D 1080 user@gateway.example.com` |
| Avec ProxyJump | `ssh -N -T -o ... -J jump.example.com -L 5432:db:5432 user@target` |
| Via alias ~/.ssh/config | `ssh -N -T -o ... -L 5432:db:5432 mon-alias` |

---

**Fin du plan.** Si tu (Claude Code) as un doute sur une décision d'architecture en cours d'implémentation, demande à Sébastien plutôt que d'inventer. Si tu vois un bug dans le plan lui-même, signale-le avant de coder.
