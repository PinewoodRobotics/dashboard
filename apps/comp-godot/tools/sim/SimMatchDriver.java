package frc.robot;

import org.wpilib.hardware.hal.AllianceStationID;
import org.wpilib.hardware.hal.RobotMode;
import org.wpilib.networktables.BooleanSubscriber;
import org.wpilib.networktables.NetworkTableInstance;
import org.wpilib.simulation.DriverStationSim;

/**
 * Sim-only full match for dashboard tests, copied into a scratch copy of the
 * robot project by tools/test/run_sim_e2e.sh --match (never into the robot repo).
 * Waits disabled until a test publishes true to START_TOPIC.
 */
public final class SimMatchDriver {
  private static final double PRE_S = 5.0;
  private static final double AUTO_S = 20.0;
  private static final double GAP_S = 2.0;
  private static final double TELEOP_S = 140.0;

  public static final String START_TOPIC = "/pwrup_test/sim_match/start";

  private static long startNs = -1;
  private static boolean attached;
  private static BooleanSubscriber start;

  private SimMatchDriver() {}

  public static void periodic() {
    if (!attached) {
      attached = true;
      start = NetworkTableInstance.getDefault().getBooleanTopic(START_TOPIC).subscribe(false);
      DriverStationSim.setDsAttached(true);
      DriverStationSim.setAllianceStationId(AllianceStationID.BLUE_1);
      DriverStationSim.setGameData("B");
    }
    if (startNs < 0 && start.get()) {
      startNs = System.nanoTime();
    }
    double t = startNs < 0 ? 0.0 : (System.nanoTime() - startNs) / 1e9;
    boolean enabled;
    RobotMode mode;
    if (t < PRE_S) {
      enabled = false;
      mode = RobotMode.AUTONOMOUS;
    } else if (t < PRE_S + AUTO_S) {
      enabled = true;
      mode = RobotMode.AUTONOMOUS;
    } else if (t < PRE_S + AUTO_S + GAP_S) {
      enabled = false;
      mode = RobotMode.TELEOPERATED;
    } else {
      enabled = t < PRE_S + AUTO_S + GAP_S + TELEOP_S + 1.0;
      mode = RobotMode.TELEOPERATED;
    }
    DriverStationSim.setRobotMode(mode);
    DriverStationSim.setEnabled(enabled);
    DriverStationSim.notifyNewData();
  }
}
