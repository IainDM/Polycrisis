import { spawn, type ChildProcess } from "child_process";
import { logger } from "./logger.js";
import {
  JULIA_WORKER_SCRIPT,
  JULIA_STARTUP_TIMEOUT_MS,
  SIMULATION_TIMEOUT_MS,
} from "../constants.js";
import type { SectorId, SectorParameters, SimulationResult } from "../earth4all/types.js";

interface JuliaWorkerState {
  process: ChildProcess | null;
  ready: boolean;
  starting: boolean;
  pendingResolve: ((value: string) => void) | null;
  pendingReject: ((reason: Error) => void) | null;
  buffer: string;
}

const state: JuliaWorkerState = {
  process: null,
  ready: false,
  starting: false,
  pendingResolve: null,
  pendingReject: null,
  buffer: "",
};

function getJuliaCommand(): string {
  return process.env.JULIA_CMD ?? "julia";
}

function getEarth4AllSrc(): string {
  return (
    process.env.EARTH4ALL_SRC ??
    new URL("../../Earth4All.jl/src", import.meta.url).pathname
  );
}

export async function ensureWorker(): Promise<void> {
  if (state.ready && state.process && !state.process.killed) {
    return;
  }

  if (state.starting) {
    // Wait for the existing startup to complete
    return new Promise((resolve, reject) => {
      const check = setInterval(() => {
        if (state.ready) {
          clearInterval(check);
          resolve();
        } else if (!state.starting) {
          clearInterval(check);
          reject(new Error("Julia worker failed to start"));
        }
      }, 500);
    });
  }

  state.starting = true;

  return new Promise((resolve, reject) => {
    const juliaCmd = getJuliaCommand();
    const e4aSrc = getEarth4AllSrc();

    logger.info(`Starting Julia worker: ${juliaCmd} ${JULIA_WORKER_SCRIPT} ${e4aSrc}`);

    const proc = spawn(juliaCmd, [JULIA_WORKER_SCRIPT, e4aSrc], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, EARTH4ALL_SRC: e4aSrc },
    });

    state.process = proc;
    state.buffer = "";

    const timeout = setTimeout(() => {
      state.starting = false;
      proc.kill();
      reject(new Error(`Julia worker startup timed out after ${JULIA_STARTUP_TIMEOUT_MS / 1000}s`));
    }, JULIA_STARTUP_TIMEOUT_MS);

    proc.stderr?.on("data", (data: Buffer) => {
      logger.debug(`Julia stderr: ${data.toString().trim()}`);
    });

    proc.stdout?.on("data", (data: Buffer) => {
      state.buffer += data.toString();

      // Process complete lines
      let newlineIdx: number;
      while ((newlineIdx = state.buffer.indexOf("\n")) !== -1) {
        const line = state.buffer.slice(0, newlineIdx).trim();
        state.buffer = state.buffer.slice(newlineIdx + 1);

        if (!line) continue;

        try {
          const msg = JSON.parse(line);

          if (!state.ready && msg.status === "ready") {
            // Worker is ready
            state.ready = true;
            state.starting = false;
            clearTimeout(timeout);
            logger.info("Julia worker is ready");
            resolve();
          } else if (state.pendingResolve) {
            // This is a response to a pending command
            const res = state.pendingResolve;
            state.pendingResolve = null;
            state.pendingReject = null;
            res(line);
          }
        } catch {
          logger.warn(`Non-JSON from Julia: ${line}`);
        }
      }
    });

    proc.on("error", (err) => {
      state.starting = false;
      state.ready = false;
      clearTimeout(timeout);
      if (state.pendingReject) {
        state.pendingReject(err);
        state.pendingResolve = null;
        state.pendingReject = null;
      }
      reject(err);
    });

    proc.on("exit", (code) => {
      state.ready = false;
      state.starting = false;
      state.process = null;
      logger.info(`Julia worker exited with code ${code}`);
      if (state.pendingReject) {
        state.pendingReject(new Error(`Julia worker exited with code ${code}`));
        state.pendingResolve = null;
        state.pendingReject = null;
      }
    });
  });
}

async function sendCommand(command: Record<string, unknown>): Promise<string> {
  await ensureWorker();

  if (!state.process || !state.process.stdin) {
    throw new Error("Julia worker is not running");
  }

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      state.pendingResolve = null;
      state.pendingReject = null;
      reject(new Error(`Julia command timed out after ${SIMULATION_TIMEOUT_MS / 1000}s`));
    }, SIMULATION_TIMEOUT_MS);

    state.pendingResolve = (value: string) => {
      clearTimeout(timeout);
      resolve(value);
    };
    state.pendingReject = (reason: Error) => {
      clearTimeout(timeout);
      reject(reason);
    };

    const json = JSON.stringify(command);
    state.process!.stdin!.write(json + "\n");
  });
}

export async function runSimulation(
  parameters: Record<string, SectorParameters>,
  initialisations?: Record<string, Record<string, number>>,
  variables?: string[],
): Promise<SimulationResult> {
  const command: Record<string, unknown> = {
    command: "run",
    parameters,
  };
  if (initialisations) {
    command.initialisations = initialisations;
  }
  if (variables) {
    command.variables = variables;
  }

  const response = await sendCommand(command);
  return JSON.parse(response) as SimulationResult;
}

export async function pingWorker(): Promise<boolean> {
  try {
    const response = await sendCommand({ command: "ping" });
    const parsed = JSON.parse(response);
    return parsed.status === "ok";
  } catch {
    return false;
  }
}

export async function shutdownWorker(): Promise<void> {
  if (state.process && !state.process.killed) {
    try {
      state.process.stdin?.write(JSON.stringify({ command: "exit" }) + "\n");
    } catch {
      // Process may already be gone
    }
    state.process.kill();
    state.process = null;
    state.ready = false;
  }
}
