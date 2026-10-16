ARG NODE_IMAGE=node:22.13.1-bookworm-slim
FROM ${NODE_IMAGE}

WORKDIR /app
COPY package.json package-lock.json ./
COPY deps/npm-cache /deps/npm-cache
RUN npm ci --offline --cache /deps/npm-cache
COPY app.js server.js ./

EXPOSE 3000
CMD ["npm", "start"]
