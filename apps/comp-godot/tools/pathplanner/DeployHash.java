import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HexFormat;
import java.util.List;
import java.util.stream.Stream;

/**
 * Hash of the robot's deploy/pathplanner folder that the Godot dashboard compares with its
 * auto export (index.json "source_hash", from source_hash() in export_autos.py). Covers what
 * the dashboard sync copies: autos/, paths/ and settings.json, skipping dot-prefixed names.
 *
 * <p>Copy into the robot code (add a package line), compute once at startup and log it every
 * loop next to ValidNames/Autos:
 *
 * <pre>
 * Logger.recordOutput("PathPlanner/DeployHash", deployHash);
 * </pre>
 *
 * Check from a shell: java DeployHash.java path/to/deploy/pathplanner
 */
public final class DeployHash {
  private DeployHash() {}

  public static String of(Path root) {
    try {
      List<String> rels = new ArrayList<>();
      for (String dir : List.of("autos", "paths")) {
        Path d = root.resolve(dir);
        if (!Files.isDirectory(d)) {
          continue;
        }
        try (Stream<Path> files = Files.walk(d)) {
          files
              .filter(Files::isRegularFile)
              .map(p -> root.relativize(p).toString().replace('\\', '/'))
              .filter(r -> Arrays.stream(r.split("/")).noneMatch(part -> part.startsWith(".")))
              .forEach(rels::add);
        }
      }
      if (Files.isRegularFile(root.resolve("settings.json"))) {
        rels.add("settings.json");
      }
      Collections.sort(rels);
      MessageDigest all = MessageDigest.getInstance("SHA-256");
      for (String rel : rels) {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(root.resolve(rel)));
        all.update((rel + "\n" + HexFormat.of().formatHex(digest) + "\n").getBytes(StandardCharsets.UTF_8));
      }
      return HexFormat.of().formatHex(all.digest());
    } catch (Exception e) {
      return "";
    }
  }

  public static void main(String[] args) {
    System.out.println(of(Path.of(args[0])));
  }
}
