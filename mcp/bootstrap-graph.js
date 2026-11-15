// Headless sign-in and graph bootstrap for the MCP container.
// Run by the bundled Electron binary as Node (ELECTRON_RUN_AS_NODE=1). Signs in with the
// account passed in the environment, then calls the app's MCP /api route to set the tokens and download the
// sync graph once. Then it quits the app so the entrypoint restarts it with
// logseq://graph/<name> and MCP opens that graph.
const fs = require('fs');
const http = require('http');
const path = require('path');

const env = process.env;
const mcpBase = `http://127.0.0.1:${env.LOGSEQ_MCP_PORT || 12315}`;
const graphName = env.LOGSEQ_GRAPH_NAME;
const markerFile = path.join(env.LOGSEQ_DATA_DIR, `.downloaded-${graphName}`);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function signIn() {
  const resp = await fetch('https://cognito-idp.us-east-1.amazonaws.com/', {
    method: 'POST',
    headers: {
      'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth',
      'Content-Type': 'application/x-amz-json-1.1',
    },
    body: JSON.stringify({
      AuthFlow: 'USER_PASSWORD_AUTH',
      ClientId: env.COGNITO_CLIENT_ID,
      AuthParameters: { USERNAME: env.LOGSEQ_USERNAME, PASSWORD: env.LOGSEQ_PASSWORD },
    }),
    signal: AbortSignal.timeout(30000),
  });
  const body = await resp.json();
  if (!resp.ok) throw new Error(`sign-in failed: ${body.__type}`);
  const result = body.AuthenticationResult;
  return {
    idToken: result.IdToken,
    accessToken: result.AccessToken,
    refreshToken: result.RefreshToken,
  };
}

function request(method, url, headers, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(url, { method, headers }, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.end(body);
  });
}

async function waitForMcp() {
  for (;;) {
    try {
      if ((await request('GET', `${mcpBase}/`, {})).status === 200) return;
    } catch (_) {
      // The app is still starting; keep polling.
    }
    await sleep(2000);
  }
}

async function callApi(method, args) {
  const res = await request(
    'POST',
    `${mcpBase}/api`,
    { 'Content-Type': 'application/json', Authorization: `Bearer ${env.LOGSEQ_MCP_TOKEN}` },
    JSON.stringify({ method, args })
  );
  const body = JSON.parse(res.body || 'null');
  if (res.status !== 200 || (body && body.error)) {
    throw new Error(`${method} failed: ${res.status} ${res.body}`);
  }
  return body;
}

async function assertRemoteGraphExists(idToken) {
  const res = await request('GET', `${env.SYNC_SERVER_URL}/graphs`, {
    Authorization: `Bearer ${idToken}`,
  });
  if (res.status !== 200) throw new Error(`listing sync graphs failed: ${res.status}`);
  const { graphs = [] } = JSON.parse(res.body);
  if (!graphs.some((graph) => graph['graph-name'] === graphName)) {
    throw new Error(`sync graph ${graphName} does not exist on ${env.SYNC_SERVER_URL}`);
  }
}

async function main() {
  if (fs.existsSync(markerFile)) {
    console.log(`graph ${graphName} already downloaded; nothing to do`);
    return;
  }

  const tokens = await signIn();
  console.log('signed in');
  await assertRemoteGraphExists(tokens.idToken);
  console.log(`sync graph ${graphName} found`);

  // Headless saves of the E2EE password read the refresh token from this file, not from worker state.
  fs.mkdirSync(path.join(env.HOME, 'logseq'), { recursive: true });
  fs.writeFileSync(path.join(env.HOME, 'logseq', 'auth.json'), JSON.stringify({ 'refresh-token': tokens.refreshToken }));

  // Nothing is created unless the sync graph exists (checked above). The download then creates the local record.
  await waitForMcp();
  // The API can answer before the db-worker finishes starting, so retry only that error.
  for (let attempt = 1; ; attempt++) {
    try {
      await callApi('app@download_graph_by_name', [
        tokens.idToken,
        tokens.accessToken,
        tokens.refreshToken,
        env.SYNC_SERVER_URL,
        graphName,
        env.LOGSEQ_E2EE_PASSWORD || null,
      ]);
      break;
    } catch (error) {
      if (attempt >= 30 || !/db-worker has not been initialized/.test(error.message)) throw error;
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }
  console.log(`downloaded ${graphName}`);

  fs.writeFileSync(markerFile, new Date().toISOString());

  // Quitting ends the app; the entrypoint restarts it with the graph open.
  try {
    await callApi('app@quit', []);
  } catch (_) {
    // The app may close before it replies.
  }
}

main().catch((error) => {
  console.error('bootstrap failed:', error.message);
  process.exit(1);
});
