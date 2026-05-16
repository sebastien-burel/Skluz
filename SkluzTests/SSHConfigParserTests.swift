import Foundation
import Testing
@testable import Skluz

struct SSHConfigParserTests {

    @Test func parsesSimpleHostBlock() {
        let config = """
        Host monserveur
            HostName monserveur.example.com
            User sebastien
            Port 2022
            IdentityFile ~/.ssh/id_ed25519
        """

        let hosts = SSHConfigParser.parse(text: config)
        #expect(hosts.count == 1)
        let h = hosts[0]
        #expect(h.aliasOrPattern == "monserveur")
        #expect(h.hostname == "monserveur.example.com")
        #expect(h.user == "sebastien")
        #expect(h.port == 2022)
        #expect(h.identityFile == "~/.ssh/id_ed25519")
    }

    @Test func handlesEqualsSeparatorAndComments() {
        // ssh_config ne gère pas les commentaires inline : seules les lignes
        // entières commençant par # sont des commentaires.
        let config = """
        # un commentaire
        Host dgx
          HostName=dgx.haruni.net
          Port = 2022
          User=sb
        """

        let h = SSHConfigParser.parse(text: config).first
        #expect(h?.aliasOrPattern == "dgx")
        #expect(h?.hostname == "dgx.haruni.net")
        #expect(h?.port == 2022)
        #expect(h?.user == "sb")
    }

    @Test func firstValueWinsWithinBlock() {
        let config = """
        Host dup
            User first
            User second
        """
        #expect(SSHConfigParser.parse(text: config).first?.user == "first")
    }

    @Test func multiplePatternsOnHostLineYieldMultipleEntries() {
        let config = """
        Host alpha beta
            User shared
        """
        let hosts = SSHConfigParser.parse(text: config)
        #expect(Set(hosts.map(\.aliasOrPattern)) == ["alpha", "beta"])
        #expect(hosts.allSatisfy { $0.user == "shared" })
    }

    @Test func wildcardHostIsNotSelectableAlias() {
        let config = """
        Host *
            User globaluser
        Host real-host
            HostName real.example.com
        """
        let hosts = SSHConfigParser.parse(text: config)
        let selectable = hosts.filter(\.isSelectableAlias).map(\.aliasOrPattern)
        #expect(selectable == ["real-host"])
    }

    @Test func matchBlockDoesNotLeakIntoHost() {
        let config = """
        Host keep
            User keepuser
        Match host "*.internal"
            User matchuser
        """
        let hosts = SSHConfigParser.parse(text: config)
        #expect(hosts.count == 1)
        #expect(hosts[0].aliasOrPattern == "keep")
        #expect(hosts[0].user == "keepuser")
    }

    @Test func quotedIdentityFileWithSpaces() {
        let config = """
        Host nvidia
            HostName dgx.haruni.net
            IdentityFile "/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key"
        """
        let h = SSHConfigParser.parse(text: config).first
        #expect(h?.identityFile == "/Users/sb/Library/Application Support/NVIDIA/Sync/config/nvsync.key")
    }

    @Test func emptyOrCommentOnlyConfigYieldsNoHosts() {
        #expect(SSHConfigParser.parse(text: "").isEmpty)
        #expect(SSHConfigParser.parse(text: "# only\n\n   \n# comments").isEmpty)
    }
}
