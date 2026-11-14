import com.pathplanner.lib.config.RobotConfig;
import com.pathplanner.lib.events.Event;
import com.pathplanner.lib.events.OneShotTriggerEvent;
import com.pathplanner.lib.events.TriggerEvent;
import com.pathplanner.lib.path.PathPlannerPath;
import com.pathplanner.lib.trajectory.PathPlannerTrajectory;
import com.pathplanner.lib.trajectory.PathPlannerTrajectoryState;
import com.pathplanner.lib.util.FlippingUtil;
import java.io.File;
import java.util.Arrays;
import java.util.List;
import java.util.function.ToDoubleFunction;
import org.wpilib.system.Filesystem;

public final class TrajectoryDump {
  private static void series(StringBuilder out, String key, List<PathPlannerTrajectoryState> states,
      ToDoubleFunction<PathPlannerTrajectoryState> f) {
    out.append('"').append(key).append("\": [");
    for (int i = 0; i < states.size(); i++) {
      if (i > 0) out.append(", ");
      out.append(Double.toString(f.applyAsDouble(states.get(i))));
    }
    out.append(']');
  }

  private static void trajectory(StringBuilder out, PathPlannerTrajectory traj) {
    List<PathPlannerTrajectoryState> s = traj.getStates();
    out.append("{");
    series(out, "t", s, st -> st.timeSeconds);
    out.append(", ");
    series(out, "x", s, st -> st.pose.getX());
    out.append(", ");
    series(out, "y", s, st -> st.pose.getY());
    out.append(", ");
    series(out, "rot", s, st -> st.pose.getRotation().getRadians());
    out.append(", ");
    series(out, "vx", s, st -> st.fieldSpeeds.vx);
    out.append(", ");
    series(out, "vy", s, st -> st.fieldSpeeds.vy);
    out.append(", ");
    series(out, "omega", s, st -> st.fieldSpeeds.omega);
    out.append(", ");
    series(out, "linear_velocity", s, st -> st.linearVelocity);
    out.append(", ");
    series(out, "heading", s, st -> st.heading.getRadians());
    out.append(", \"events\": [");
    boolean first = true;
    for (Event e : traj.getEvents()) {
      String item;
      if (e instanceof TriggerEvent te) {
        item = String.format("{\"type\": \"trigger\", \"name\": \"%s\", \"active\": %b, \"t\": %s}",
            te.getEventName(), te.getValue(), Double.toString(e.getTimestampSeconds()));
      } else if (e instanceof OneShotTriggerEvent oe) {
        item = String.format("{\"type\": \"one_shot\", \"name\": \"%s\", \"t\": %s}",
            oe.getEventName(), Double.toString(e.getTimestampSeconds()));
      } else {
        item = String.format("{\"type\": \"%s\", \"t\": %s}", e.getClass().getSimpleName(),
            Double.toString(e.getTimestampSeconds()));
      }
      out.append(first ? "" : ", ").append(item);
      first = false;
    }
    out.append("]}");
  }

  public static void main(String[] args) throws Exception {
    RobotConfig config = RobotConfig.fromGUISettings();
    File dir = new File(Filesystem.getDeployDirectory(), "pathplanner/paths");
    String[] files = dir.list((d, n) -> n.endsWith(".path"));
    if (files == null || files.length == 0) {
      throw new IllegalStateException("no .path files in " + dir.getAbsolutePath());
    }
    Arrays.sort(files);
    StringBuilder out = new StringBuilder();
    out.append(String.format("{\"field\": {\"length_m\": %s, \"width_m\": %s, \"symmetry\": \"%s\"},\n \"paths\": [\n",
        Double.toString(FlippingUtil.fieldSizeX), Double.toString(FlippingUtil.fieldSizeY), FlippingUtil.symmetryType));
    for (int i = 0; i < files.length; i++) {
      String name = files[i].substring(0, files[i].length() - ".path".length());
      PathPlannerPath path = PathPlannerPath.fromPathFile(name);
      PathPlannerTrajectory red = path.getIdealTrajectory(config).orElseThrow();
      PathPlannerTrajectory blue = path.flipPath().getIdealTrajectory(config).orElseThrow();
      out.append(String.format("  {\"name\": \"%s\", \"duration_s\": %s, \"red\": ", name,
          Double.toString(red.getTotalTimeSeconds())));
      trajectory(out, red);
      out.append(", \"blue\": ");
      trajectory(out, blue);
      out.append(i + 1 < files.length ? "},\n" : "}\n");
    }
    out.append(" ]}\n");
    System.out.print(out);
    System.exit(0);
  }
}
