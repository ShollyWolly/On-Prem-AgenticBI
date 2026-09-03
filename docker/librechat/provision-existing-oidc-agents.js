// This maintenance entry point provisions governed agents for existing OIDC users.
const path = require('path');
const mongoose = require('mongoose');

require('module-alias')({ base: path.resolve(__dirname, '../..') });

const { createModels } = require('@librechat/data-schemas');

createModels(mongoose);

const { provisionOidcAgents } = require('./oidc-agent-provisioning');

async function main() {
  await mongoose.connect(process.env.MONGO_URI);
  try {
    const users = await mongoose.connection.db
      .collection('users')
      .find({ provider: 'openid' })
      .toArray();
    for (const user of users) {
      await provisionOidcAgents(user);
    }
    console.log(`Provisioned managed agents for ${users.length} OIDC users.`);
  } finally {
    await mongoose.disconnect();
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(`Managed agent provisioning failed: ${error.message}`);
    process.exit(1);
  });
