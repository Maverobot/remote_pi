import 'package:cockpit/app/cockpit/domain/contracts/rpc_process_gateway.dart';

/// Fábrica de gateways RPC — **um por agente** (multiplexação da Wave 2).
///
/// Contrato no domínio; a impl (`data/`) constrói um `PiRpcProcess` novo a cada
/// chamada. A `ui/` (sessão do agente) pede um gateway aqui em vez de instanciar
/// `data/` direto, preservando o fluxo `ui → domain ← data`.
abstract class RpcGatewayFactory {
  RpcProcessGateway create();
}
