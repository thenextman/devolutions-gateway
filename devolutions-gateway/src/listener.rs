use crate::config::Config;
use crate::generic_client::GenericClient;
use crate::jet_client::{JetAssociationsMap, JetClient};
use crate::rdp::RdpClient;
use crate::routing_client;
use crate::token::{CurrentJrl, TokenCache};
use crate::utils::url_to_socket_addr;
use crate::websocket_client::{WebsocketService, WsClient};
use anyhow::Context;
use hyper::service::service_fn;
use slog::Logger;
use slog_scope_futures::future03::FutureExt;
use std::net::SocketAddr;
use std::sync::Arc;
use tap::Pipe as _;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, TcpSocket, TcpStream};
use tokio_rustls::TlsStream;
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListenerKind {
    Tcp,
    Ws,
    Wss,
}

pub struct GatewayListener {
    addr: SocketAddr,
    kind: ListenerKind,
    listener: TcpListener,
    associations: Arc<JetAssociationsMap>,
    token_cache: Arc<TokenCache>,
    jrl: Arc<CurrentJrl>,
    config: Arc<Config>,
    logger: Logger,
}

impl GatewayListener {
    pub fn init_and_bind(
        url: Url,
        config: Arc<Config>,
        associations: Arc<JetAssociationsMap>,
        token_cache: Arc<TokenCache>,
        jrl: Arc<CurrentJrl>,
        logger: Logger,
    ) -> anyhow::Result<Self> {
        info!("Initiating listener {}…", url);

        let socket_addr = url_to_socket_addr(&url).context("invalid url")?;

        let socket = TcpSocket::new_v4().context("failed to create TCP socket")?;
        socket.bind(socket_addr).context("failed to bind TCP socket")?;
        set_socket_options(&socket, &logger);
        let listener = socket
            .listen(64)
            .context("failed to listen with the binded TCP socket")?;

        let kind = match url.scheme() {
            "tcp" => ListenerKind::Tcp,
            "ws" => ListenerKind::Ws,
            "wss" => ListenerKind::Wss,
            unsupported => anyhow::bail!("unsupported listener scheme: {}", unsupported),
        };

        info!("TCP listener on {} started successfully", socket_addr);

        let logger = logger.new(slog::o!("listener" => url.to_string()));

        Ok(Self {
            addr: socket_addr,
            kind,
            listener,
            config,
            associations,
            token_cache,
            jrl,
            logger,
        })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn kind(&self) -> ListenerKind {
        self.kind
    }

    pub async fn run(self) -> anyhow::Result<()> {
        macro_rules! handle {
            ($handler:ident) => {{
                match self.listener.accept().await.context("failed to accept connection") {
                    Ok((stream, peer_addr)) => {
                        let config = self.config.clone();
                        let associations = self.associations.clone();
                        let token_cache = self.token_cache.clone();
                        let jrl = self.jrl.clone();
                        let logger = self.logger.new(slog::o!("client" => peer_addr.to_string()));

                        tokio::spawn(async move {
                            if let Err(e) = $handler(config, associations, token_cache, jrl, stream, peer_addr, logger.clone()).await {
                                slog_error!(logger, concat!(stringify!($handler), " failure: {:#}"), e);
                            }
                        });
                    }
                    Err(e) => slog_warn!(self.logger, "listener failure: {:#}", e),
                }
            }}
        }

        match self.kind() {
            ListenerKind::Tcp => loop {
                handle!(handle_tcp_client)
            },
            ListenerKind::Ws => loop {
                handle!(handle_ws_client)
            },
            ListenerKind::Wss => loop {
                handle!(handle_wss_client)
            },
        }
    }

    pub async fn handle_one(&self) -> anyhow::Result<()> {
        let (conn, peer_addr) = self.listener.accept().await.context("failed to accept connection")?;

        let config = self.config.clone();
        let associations = self.associations.clone();
        let token_cache = self.token_cache.clone();
        let jrl = self.jrl.clone();
        let logger = self.logger.new(slog::o!("client" => peer_addr.to_string()));

        match self.kind() {
            ListenerKind::Tcp => {
                handle_tcp_client(config, associations, token_cache, jrl, conn, peer_addr, logger).await?
            }
            ListenerKind::Ws => {
                handle_ws_client(config, associations, token_cache, jrl, conn, peer_addr, logger).await?
            }
            ListenerKind::Wss => {
                handle_wss_client(config, associations, token_cache, jrl, conn, peer_addr, logger).await?
            }
        }

        Ok(())
    }
}

async fn handle_tcp_client(
    config: Arc<Config>,
    associations: Arc<JetAssociationsMap>,
    token_cache: Arc<TokenCache>,
    jrl: Arc<CurrentJrl>,
    stream: TcpStream,
    peer_addr: SocketAddr,
    logger: Logger,
) -> anyhow::Result<()> {
    set_stream_option(&stream, &logger);

    if let Some(routing_url) = &config.routing_url {
        // TODO: should we keep support for this "routing URL" option? (it's not really used in
        // real world usecases)
        match routing_url.scheme() {
            "tcp" => {
                routing_client::Client::new(routing_url.clone(), config)
                    .serve(peer_addr, stream)
                    .with_logger(logger)
                    .await?;
            }
            "tls" => {
                let tls_stream = config
                    .tls
                    .as_ref()
                    .unwrap()
                    .acceptor
                    .accept(stream)
                    .await
                    .context("TlsAcceptor handshake failed")?;

                routing_client::Client::new(routing_url.clone(), config)
                    .serve(peer_addr, tls_stream)
                    .with_logger(logger)
                    .await?;
            }
            "ws" => {
                let stream = tokio_tungstenite::accept_async(stream)
                    .await
                    .context("WebSocket handshake failed")?;
                let ws = transport::WebSocketStream::new(stream);
                WsClient::new(routing_url.clone(), config)
                    .serve(peer_addr, ws)
                    .with_logger(logger)
                    .await?;
            }
            "wss" => {
                let tls_stream = config
                    .tls
                    .as_ref()
                    .unwrap()
                    .acceptor
                    .accept(stream)
                    .await
                    .context("TLS handshake failed")?;
                let stream = tokio_tungstenite::accept_async(TlsStream::Server(tls_stream))
                    .await
                    .context("WebSocket handshake failed")?;
                let ws = transport::WebSocketStream::new(stream);
                WsClient::new(routing_url.clone(), config)
                    .serve(peer_addr, ws)
                    .with_logger(logger)
                    .await?;
            }
            "rdp" => {
                RdpClient {
                    config,
                    associations,
                    token_cache,
                    jrl,
                }
                .serve(stream)
                .with_logger(logger)
                .await?;
            }
            scheme => anyhow::bail!("Unsupported routing URL scheme {}", scheme),
        }
    } else {
        let mut peeked = [0; 4];
        let n_read = stream
            .peek(&mut peeked)
            .await
            .context("couldn't peek four first bytes")?;

        // Check if first four bytes contains some protocol magic bytes
        match &peeked[..n_read] {
            [b'J', b'E', b'T', b'\0'] => {
                JetClient::builder()
                    .config(config)
                    .associations(associations)
                    .addr(peer_addr)
                    .transport(stream)
                    .build()
                    .serve()
                    .with_logger(logger)
                    .await?;
            }
            [b'J', b'M', b'U', b'X'] => anyhow::bail!("JMUX TCP listener not yet implemented"),
            _ => {
                GenericClient::builder()
                    .config(config)
                    .associations(associations)
                    .client_addr(peer_addr)
                    .client_stream(stream)
                    .token_cache(token_cache)
                    .jrl(jrl)
                    .build()
                    .serve()
                    .with_logger(logger)
                    .await?;
            }
        }
    };

    Ok(())
}

async fn handle_ws_client(
    config: Arc<Config>,
    associations: Arc<JetAssociationsMap>,
    token_cache: Arc<TokenCache>,
    jrl: Arc<CurrentJrl>,
    conn: TcpStream,
    peer_addr: SocketAddr,
    logger: Logger,
) -> anyhow::Result<()> {
    set_stream_option(&conn, &logger);

    // Annonate using the type alias from `transport` just for sanity
    let conn: transport::TcpStream = conn;

    process_ws_stream(conn, peer_addr, config, associations, token_cache, jrl, logger).await?;

    Ok(())
}

async fn handle_wss_client(
    config: Arc<Config>,
    associations: Arc<JetAssociationsMap>,
    token_cache: Arc<TokenCache>,
    jrl: Arc<CurrentJrl>,
    stream: TcpStream,
    peer_addr: SocketAddr,
    logger: Logger,
) -> anyhow::Result<()> {
    set_stream_option(&stream, &logger);

    let tls_conf = config.tls.as_ref().context("TLS configuration is missing")?;

    // Annotate using the type alias from `transport` just for sanity
    let tls_stream: transport::TlsStream = tls_conf
        .acceptor
        .accept(stream)
        .await
        .context("TLS handshake failed")?
        .pipe(tokio_rustls::TlsStream::Server);

    process_ws_stream(tls_stream, peer_addr, config, associations, token_cache, jrl, logger).await?;

    Ok(())
}

async fn process_ws_stream<I>(
    io: I,
    remote_addr: SocketAddr,
    config: Arc<Config>,
    associations: Arc<JetAssociationsMap>,
    token_cache: Arc<TokenCache>,
    jrl: Arc<CurrentJrl>,
    logger: Logger,
) -> anyhow::Result<()>
where
    I: AsyncWrite + AsyncRead + Unpin + Send + Sync + 'static,
{
    let websocket_service = WebsocketService {
        associations,
        config,
        token_cache,
        jrl,
    };

    let service = service_fn(move |req| {
        let mut ws_serve = websocket_service.clone();
        async move {
            ws_serve.handle(req, remote_addr).await.map_err(|e| {
                debug!("WebSocket HTTP server error: {}", e);
                e
            })
        }
    });

    let http = hyper::server::conn::Http::new();

    http.serve_connection(io, service)
        .with_upgrades()
        .with_logger(logger)
        .await?;

    Ok(())
}

fn set_socket_options(socket: &TcpSocket, logger: &Logger) {
    const SOCKET_SEND_BUFFER_SIZE: u32 = 0x7FFFF;
    const SOCKET_RECV_BUFFER_SIZE: u32 = 0x7FFFF;

    // FIXME: temporarily not available in tokio 1.x (https://github.com/tokio-rs/tokio/issues/3082)
    // if let Err(e) = socket.set_keepalive(Some(Duration::from_secs(2))) {
    //     slog_error!(logger, "set_keepalive on TcpStream failed: {}", e);
    // }

    if let Err(e) = socket.set_send_buffer_size(SOCKET_SEND_BUFFER_SIZE) {
        slog_error!(logger, "set_send_buffer_size on TcpStream failed: {}", e);
    }

    if let Err(e) = socket.set_recv_buffer_size(SOCKET_RECV_BUFFER_SIZE) {
        slog_error!(logger, "set_recv_buffer_size on TcpStream failed: {}", e);
    }
}

fn set_stream_option(stream: &TcpStream, logger: &Logger) {
    if let Err(e) = stream.set_nodelay(true) {
        slog_error!(logger, "set_nodelay on TcpStream failed: {}", e);
    }
}