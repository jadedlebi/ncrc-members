FROM nginx:1.27-alpine

COPY index.html /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
COPY css/ /usr/share/nginx/html/css/
COPY data/ /usr/share/nginx/html/data/
COPY js/ /usr/share/nginx/html/js/
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
