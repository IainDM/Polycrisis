import fs from "fs/promises";
import path from "path";
import { PROJECTS_DIR } from "../constants.js";

export async function writeToolOutput(
  projectId: string,
  filename: string,
  content: string,
): Promise<string> {
  const dir = path.join(PROJECTS_DIR, projectId, "outputs");
  await fs.mkdir(dir, { recursive: true });
  const filePath = path.join(dir, filename);
  await fs.writeFile(filePath, content);
  return filePath;
}
