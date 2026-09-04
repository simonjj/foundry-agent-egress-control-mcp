FROM mcr.microsoft.com/playwright:v1.62.1-noble

ENV NODE_ENV=production \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    MCP_PORT=8080 \
    PLAYWRIGHT_MCP_PORT=8931

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev \
    && ./node_modules/.bin/playwright-mcp install-browser chrome-for-testing \
    && npm cache clean --force

COPY server.mjs ./

USER pwuser
EXPOSE 8080
CMD ["node", "server.mjs"]
