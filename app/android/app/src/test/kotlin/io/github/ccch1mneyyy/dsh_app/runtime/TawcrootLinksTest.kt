package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Paths
import java.nio.file.attribute.FileTime
import java.nio.file.attribute.PosixFilePermissions
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Fixtures follow tawc's link store format 1 (tawcroot/include/linkstore.h at the pinned commit). */
class TawcrootLinksTest {
    private val base = kotlin.io.path.createTempDirectory("tawc-links").toFile()
    private val root = File(base, "rootfs").apply { mkdirs() }.canonicalFile
    private val store = File(base, "tawcroot")
    private var flushes = 0

    @After fun cleanUp() { base.deleteRecursively() }

    private fun obj(token: String, text: String, mode: String = "rwxr-x---"): File =
        File(store, "link/$token").apply {
            parentFile.mkdirs()
            writeText(text)
            Files.setPosixFilePermissions(toPath(), PosixFilePermissions.fromString(mode))
            Files.setLastModifiedTime(toPath(), FileTime.fromMillis(1_700_000_000_000))
            File(store, "link/$token.cnt").writeText("%010d\n".format(2))
        }

    private fun name(path: String, token: String) = File(root, path).apply {
        parentFile.mkdirs()
        Files.createSymbolicLink(toPath(), Paths.get(TawcrootLinks.PREFIX + token))
    }

    private fun migration(free: Long = Long.MAX_VALUE, within: List<String>? = null) =
        TawcrootLinks(root, { flushes++ }, { free }, within)

    @Test fun nothingToDoWithoutAStore() {
        assertFalse(TawcrootLinks.pending(root))
        assertEquals(TawcrootLinks.Result.Done(0, false), migration().run())
    }

    @Test fun everyNameBecomesItsOwnFileAndTheStoreGoes() {
        obj("1234", "shared content")
        val a = name("root/a/pkg.js", "1234")
        val b = name("root/.local/share/pnpm/store/x", "1234")
        File(root, "root/plain.txt").writeText("untouched")
        Files.createSymbolicLink(File(root, "root/rel").toPath(), Paths.get("plain.txt"))
        assertTrue(TawcrootLinks.pending(root))

        assertEquals(TawcrootLinks.Result.Done(2, true), migration().run())
        for (file in listOf(a, b)) {
            assertFalse(Files.isSymbolicLink(file.toPath()))
            assertEquals("shared content", file.readText())
            assertEquals("rwxr-x---", PosixFilePermissions.toString(Files.getPosixFilePermissions(file.toPath())))
            assertEquals(1_700_000_000_000, Files.getLastModifiedTime(file.toPath()).toMillis())
        }
        assertEquals("plain.txt", Files.readSymbolicLink(File(root, "root/rel").toPath()).toString())
        assertFalse(store.exists())
        assertFalse(TawcrootLinks.pending(root))
        assertTrue(flushes > 0)
    }

    @Test fun unreadableBindMountPointsDoNotKeepTheStore() {
        obj("4", "x")
        name("root/n", "4")
        val system = File(root, "system").apply { mkdirs() }
        Files.setPosixFilePermissions(system.toPath(), PosixFilePermissions.fromString("---------"))
        try {
            assertEquals(TawcrootLinks.Result.Done(1, true), migration().run())
        } finally {
            Files.setPosixFilePermissions(system.toPath(), PosixFilePermissions.fromString("rwx------"))
        }
    }

    @Test fun anUnreadableOrdinaryDirectoryKeepsTheStore() {
        obj("6", "x")
        name("root/n", "6")
        val home = File(root, "home").apply { mkdirs() }
        Files.setPosixFilePermissions(home.toPath(), PosixFilePermissions.fromString("---------"))
        try {
            val result = migration().run() as TawcrootLinks.Result.Done
            // Running as root (some CI containers) reads it anyway.
            if (home.canRead()) return
            assertTrue(result.unseen)
            assertFalse(result.storeRemoved)
            assertTrue(store.exists())
        } finally {
            Files.setPosixFilePermissions(home.toPath(), PosixFilePermissions.fromString("rwx------"))
        }
    }

    @Test fun aLinkedSymlinkStaysASymlink() {
        File(store, "link").mkdirs()
        Files.createSymbolicLink(File(store, "link/77").toPath(), Paths.get("../lib/libz.so.1"))
        val name = name("usr/lib/libz.so", "77")
        migration().run()
        assertEquals("../lib/libz.so.1", Files.readSymbolicLink(name.toPath()).toString())
    }

    @Test fun notEnoughSpaceChangesNothing() {
        obj("5", "x".repeat(10_000))
        val a = name("root/a", "5")
        val result = migration(free = 1L shl 20).run()
        assertTrue(result is TawcrootLinks.Result.NotEnoughSpace)
        assertTrue(Files.isSymbolicLink(a.toPath()))
        assertTrue(store.exists())
    }

    @Test fun aMissingObjectKeepsTheStore() {
        obj("1", "one")
        val good = name("root/good", "1")
        val dangling = name("root/dangling", "2")
        assertEquals(TawcrootLinks.Result.Done(1, false, unseen = true), migration().run())
        assertEquals("one", good.readText())
        assertTrue(Files.isSymbolicLink(dangling.toPath()))
        assertTrue(store.exists())
    }

    @Test fun aResetOnlyConvertsWhatItKeeps() {
        obj("9", "kept")
        val kept = name("root/workspace/a", "9")
        val other = name("usr/share/b", "9")
        assertEquals(TawcrootLinks.Result.Done(1, false), migration(within = listOf("root/workspace")).run())
        assertEquals("kept", kept.readText())
        assertTrue(Files.isSymbolicLink(other.toPath()))
    }

    @Test fun leftoverCopiesFromAKilledRunAreRemoved() {
        obj("3", "data")
        name("root/n", "3")
        val stale = File(root, "root/.dsh-go-tawc-0123456789abcdef.tmp").apply { writeText("partial") }
        migration().run()
        assertFalse(Files.exists(stale.toPath(), LinkOption.NOFOLLOW_LINKS))
    }
}
