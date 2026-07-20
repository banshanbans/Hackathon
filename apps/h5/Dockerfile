FROM node:24-bookworm-slim AS build

WORKDIR /app

COPY package.json package-lock.json ./
COPY apps/h5/package.json apps/h5/package.json
RUN npm ci

COPY apps/h5 apps/h5
COPY packages/contracts packages/contracts
COPY packages/evals/test-image-v1 packages/evals/test-image-v1

ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
RUN npm run build --workspace @soloshot/h5

FROM nginx:1.29-alpine

COPY apps/h5/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/apps/h5/dist /usr/share/nginx/html

EXPOSE 8080
