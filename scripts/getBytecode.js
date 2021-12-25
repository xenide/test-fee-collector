const ethers = require("ethers");
const path = require("path")
const fs = require("fs");
const VEX_V2_CORE = __dirname + "/../lib/vexchange-contracts/vexchange-v2-core/build";

const build = JSON.parse(fs.readFileSync(
    path.join(VEX_V2_CORE, "/VexchangeV2Factory.json"),
    { encoding: "ascii" },
));

process.stdout.write("0x" + build.bytecode);
