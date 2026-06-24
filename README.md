<div align="center">
  <img src="My%20Prompt%20Gallery/Assets.xcassets/AppIcon.appiconset/Icon-ios-1024.png" width="160" height="160" alt="My Prompt Gallery app icon">
  <h1>My Prompt Gallery</h1>
  <p><strong>Uma galeria pessoal para organizar, encontrar e reutilizar prompts de geração de imagens.</strong></p>
</div>

My Prompt Gallery é um app iOS criado para quem trabalha com imagens geradas por IA e quer manter seus melhores prompts sempre à mão. Salve prompts com imagens de referência, organize sua biblioteca visual, encontre ideias rapidamente e mantenha um histórico prático do que funcionou.

## Recursos

- Salve prompts com texto e imagem anexada.
- Navegue pela biblioteca em lista ou grade.
- Pesquise por texto do prompt e metadados gerados.
- Use Apple Intelligence para resumir, classificar e extrair palavras-chave dos prompts.
- Filtre a galeria por palavras-chave recorrentes.
- Copie prompts rapidamente para reutilizar em outras ferramentas.
- Valide mídia, identifique prompts duplicados e exporte os dados em CSV.
- Sincronize a biblioteca com iCloud via SwiftData e CloudKit.

## Tecnologia

- SwiftUI
- SwiftData
- CloudKit
- PhotosUI
- Apple Intelligence com Foundation Models, quando disponível

## Requisitos

- Xcode 16 ou superior
- iOS 17.0 ou superior
- Conta iCloud configurada para sincronização via CloudKit
- Dispositivo compatível com Apple Intelligence para geração automática de metadados

## Como executar

1. Abra `My Prompt Gallery.xcodeproj` no Xcode.
2. Selecione o scheme `My Prompt Gallery`.
3. Escolha um simulador ou dispositivo iOS.
4. Execute o app com `Cmd + R`.

## Privacidade

O app armazena a biblioteca do usuário no dispositivo e usa o container privado do iCloud para sincronização. A política de privacidade está disponível em:

https://pedromopi.github.io/apps/my-prompt-gallery/privacy.html
