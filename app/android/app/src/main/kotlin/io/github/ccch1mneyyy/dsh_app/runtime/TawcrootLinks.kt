package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.SecureRandom

/**
 * Turns tawcroot's emulated hard links back into real files. tawcroot (tawc's
 * link store, format 1) moves a file that gets a second name to
 * `<runtime>/tawcroot/link/<token>` and makes every name a symlink whose target
 * is the literal `tawcroot:link:<token>`. Only tawcroot can read such a name, so
 * before PRoot or Direct start, each name gets a copy of its object (mode and
 * mtime kept) renamed over it. One rename per name: a killed run leaves every
 * name readable by tawcroot or already a file, and the next start carries on.
 *
 * [within] limits the walk to these rootfs-relative paths (what a reset keeps);
 * otherwise the whole rootfs is converted and the store removed once nothing
 * refers to it.
 */
class TawcrootLinks(
    rootfs: File,
    private val flush: () -> Unit,
    private val freeBytes: () -> Long = { rootfs.usableSpace },
    private val within: List<String>? = null,
) {
    sealed class Result {
        /** [names] became real files; [storeRemoved] when the whole tree was done; [unseen] when a
         * directory could not be read or a name's object is gone (the store then stays). */
        data class Done(val names: Int, val storeRemoved: Boolean, val unseen: Boolean = false) : Result()
        data class NotEnoughSpace(val need: Long, val free: Long) : Result()
    }

    private val root = rootfs.canonicalFile.toPath()
    private val store = storeOf(rootfs).toPath()
    private val objects = store.resolve("link")
    private val random = SecureRandom()

    /** Throws on an IO error, leaving every name readable. [onSlow] runs once when this takes more than a moment. */
    fun run(onSlow: () -> Unit = {}): Result {
        if (!pending(root.toFile())) return Result.Done(0, false)
        val started = System.nanoTime()
        var slow = false
        fun tick() {
            if (!slow && System.nanoTime() - started > SLOW_NANOS) { slow = true; onSlow() }
        }

        val names = ArrayList<Pair<Path, Path>>()
        // A name we could not see or whose object is gone: keep the store for it.
        var incomplete = false
        val starts = within?.map { root.resolve(it.trimStart('/')).normalize() }?.filter { it.startsWith(root) } ?: listOf(root)
        for (start in starts) {
            try {
                Files.readAttributes(start, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
            } catch (_: NoSuchFileException) {
                continue
            } catch (_: IOException) {
                incomplete = true // can't tell: never treat it as absent
                continue
            }
            Files.walkFileTree(start, object : SimpleFileVisitor<Path>() {
                override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult {
                    // The runtime's and phone storage's bind mount points can't be read by the app,
                    // and tawcroot never stores links through a bind.
                    if (file.parent != root || file.fileName.toString() !in MOUNT_POINTS) incomplete = true
                    return FileVisitResult.CONTINUE
                }

                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    tick()
                    if (attrs.isSymbolicLink) {
                        val target = Files.readSymbolicLink(file).toString()
                        if (target.startsWith(PREFIX)) {
                            val token = target.removePrefix(PREFIX)
                            val obj = objects.resolve(token)
                            if (TOKEN.matches(token) && Files.exists(obj, LinkOption.NOFOLLOW_LINKS)) names += file to obj
                            else incomplete = true
                        }
                    } else if (attrs.isRegularFile && TEMP.matches(file.fileName.toString())) {
                        Files.delete(file) // a copy from a run that was killed before its rename
                    }
                    return FileVisitResult.CONTINUE
                }
            })
        }

        val need = names.sumOf { (_, obj) -> if (Files.isSymbolicLink(obj)) 0L else blocks(Files.size(obj)) }
        if (need > 0) {
            val free = freeBytes()
            if (free < need + L2sMigration.MARGIN) return Result.NotEnoughSpace(need, free)
        }

        var done = 0
        for (batch in names.sortedBy { it.first }.chunked(BATCH)) {
            val copies = ArrayList<Pair<Path, Path>>()
            try {
                for ((name, obj) in batch) {
                    tick()
                    val temp = name.resolveSibling(TEMP_PREFIX + "%016x".format(random.nextLong()) + ".tmp")
                    if (Files.isSymbolicLink(obj)) Files.createSymbolicLink(temp, Files.readSymbolicLink(obj))
                    else Files.copy(obj, temp, StandardCopyOption.COPY_ATTRIBUTES, LinkOption.NOFOLLOW_LINKS)
                    copies += temp to name
                }
                flush()
                for ((temp, name) in copies) {
                    Files.move(temp, name, StandardCopyOption.ATOMIC_MOVE)
                    done++
                }
            } finally {
                for ((temp, _) in copies) runCatching { Files.deleteIfExists(temp) }
            }
        }
        if (within != null || incomplete) return Result.Done(done, false, incomplete)
        flush()
        deleteTree(store)
        return Result.Done(done, true)
    }

    private fun deleteTree(dir: Path) {
        Files.walkFileTree(dir, object : SimpleFileVisitor<Path>() {
            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                Files.deleteIfExists(file)
                return FileVisitResult.CONTINUE
            }

            override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
                if (exc != null) throw exc
                Files.deleteIfExists(dir)
                return FileVisitResult.CONTINUE
            }
        })
    }

    companion object {
        const val PREFIX = "tawcroot:link:"
        private val MOUNT_POINTS = setOf("system", "apex", "sdcard", "storage", "dev", "proc", "sys")
        private val TOKEN = Regex("[0-9]+(-[0-9]+)?")
        const val TEMP_PREFIX = ".dsh-go-tawc-"
        val TEMP = Regex("""\.dsh-go-tawc-[0-9a-f]{16}\.tmp""")
        private const val SLOW_NANOS = 500_000_000L
        private const val BATCH = 2000

        private fun blocks(size: Long) = 4096 + (size + 4095) / 4096 * 4096

        /** tawcroot derives its store from the rootfs: `<rootfs>/../tawcroot`. */
        fun storeOf(rootfs: File): File = File(rootfs.canonicalFile.parentFile, "tawcroot")

        /** Whether tawcroot ever stored a linked file for this rootfs. */
        fun pending(rootfs: File): Boolean = try {
            val dir = File(storeOf(rootfs), "link").toPath()
            Files.isDirectory(dir, LinkOption.NOFOLLOW_LINKS) && Files.newDirectoryStream(dir).use { it.iterator().hasNext() }
        } catch (_: NoSuchFileException) { false }
    }
}
