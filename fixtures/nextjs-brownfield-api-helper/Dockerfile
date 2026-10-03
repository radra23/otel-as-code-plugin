FROM node:20-bookworm-slim
WORKDIR /app
COPY . .
RUN npm install && npm run build
CMD ["npm", "start"]
