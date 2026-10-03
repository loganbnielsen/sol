import { runContractCli } from "@sol-fab/kafka";
import { CONTRACT_EVENTS } from "./contracts.js";

runContractCli(CONTRACT_EVENTS)
  .then((code) => process.exit(code))
  .catch((error) => {
    console.error(String(error));
    process.exit(1);
  });
