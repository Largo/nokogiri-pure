// Runs a Ruby script under ruby.wasm (Ruby 4.0) with the WASI layer the browser build uses
// (@bjorn3/browser_wasi_shim + in-memory filesystem), i.e. what a web page gets, minus the DOM.
//
//   node run.mjs SCRIPT [NAME=DIR ...]
//
// nokogiri-pure's lib/ is mounted at /gems/nokogiri and put on the load path; each extra NAME=DIR
// (e.g. another gem's lib/) is mounted at /gems/NAME and put on the load path too. The directory
// holding SCRIPT is mounted at /work (the working directory).
import { readFile, readdir, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ConsoleStdout, Directory, File, OpenFile, PreopenDirectory, WASI } from "@bjorn3/browser_wasi_shim";
import { RubyVM } from "@ruby/wasm-wasi/dist/vm";

const here = dirname(fileURLToPath(import.meta.url));
const [script, ...extra] = process.argv.slice(2);

async function tree(dir) {
  const entries = new Map();
  for (const name of await readdir(dir)) {
    if (name === "node_modules" || name === ".git") continue;
    const full = join(dir, name);
    entries.set(name, (await stat(full)).isDirectory() ? new Directory(await tree(full)) : new File(await readFile(full)));
  }
  return entries;
}

const libs = [["nokogiri", join(here, "../lib")], ...extra.map((a) => a.split("="))];
const gems = new Map();
for (const [name, path] of libs) gems.set(name, new Directory(await tree(resolve(path))));
const root = new Map([["gems", new Directory(gems)], ["work", new Directory(await tree(dirname(resolve(script))))]]);

const fds = [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered((line) => process.stdout.write(`${line}\n`)),
  ConsoleStdout.lineBuffered((line) => process.stderr.write(`${line}\n`)),
  new PreopenDirectory("/", root),
];
const wasi = new WASI([], [], fds, { debug: false });
const wasm = await readFile(join(here, "node_modules/@ruby/4.0-wasm-wasi/dist/ruby+stdlib.wasm"));
const { vm } = await RubyVM.instantiateModule({ module: await WebAssembly.compile(wasm), wasip1: wasi });

try {
  const loadPath = libs.map(([name]) => `"/gems/${name}"`).join(", ");
  vm.eval(`$LOAD_PATH.unshift(${loadPath}); Dir.chdir("/work")`);
  vm.eval(await readFile(script, "utf8"));
} catch (error) {
  process.stderr.write(`${error?.message ?? error}\n`);
  process.exitCode = 1;
}
