# Greenfield Next.js fixture. The e2e stack does not build this image (docker-compose runs the
# app from a bind-mounted throwaway copy); it exists for parity with the other fixtures and so
# the app is runnable standalone.
FROM node:20-bookworm-slim
WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
RUN npm run build
EXPOSE 3000
CMD ["npm", "start"]
