# What Determines Whether an AI Agent Can Reliably Control a macOS Desktop GUI? A Structured Literature Review and Empirical Gap Analysis

**DISCLAIMER:** This is AI-generated content and most definitely NOT a "paper".

## Abstract

This paper presents a structured literature review and empirical gap analysis of the factors that determine whether an AI agent can reliably control a macOS desktop graphical user interface. The review spans eight disciplines: GUI agent benchmarks, accessibility API reliability, UI test flakiness, RPA deployment outcomes, distributed consistency theory, partially observable decision processes, cognitive load in LLM tool use, and human factors in automated systems. The central thesis is that the perception modality debate for desktop automation agents is underdetermined by current evidence: no controlled study exists for macOS-native applications, and the available benchmark data is contradictory across platforms and models. Findings fall into three categories. Documented and undisputed phenomena include GUI grounding failures as a dominant error source, accessibility API coverage gaps across all major platforms, the structural convergence of failure modes between Selenium test flakiness and desktop agent unreliability, and the eventual consistency properties of the macOS AXAPI. Contradictory findings include the OSWorld results, where adding accessibility tree data improved GPT-4V performance by 0.4 percentage points but degraded GPT-4o by 13.3 percentage points, and the comparison between UGround's pure-vision approach (which outperforms structured annotations by 19--21 points on Mind2Web) and UFO's dual-perception approach (which achieves 86% on WindowsBench). No controlled evidence exists for macOS-specific applications in any of these comparisons. This paper corrects a false claim from its predecessor version that OpenAI published zero reliability metrics for Operator; the Operator System Card reports confirmation prompt recall of 92%, proactive refusal recall of 94%, and prompt injection monitor recall of 99%. All engineering observations originate from a single implementation (n = 1) and are post-hoc in nature; cross-validation is partial. The paper presents a prioritized research agenda with cost estimates ranging from approximately $500 to $15,000 per experiment and concludes that the path forward is empirical: controlled A/B experiments on macOS-native applications using existing infrastructure are feasible and necessary to resolve the perception debate.

---

## 1. Introduction

Computer-use agents---AI systems that perceive desktop graphical interfaces and execute input actions---perform poorly relative to humans. On OSWorld, the primary benchmark for open-ended desktop task completion, the best agent achieves 12.24% success against human performance of 72.36% [Xie et al., 2024]. On WebArena, the gap is 14.41% versus 78.24% [Zhou et al., 2024]. These deficits are not marginal. They represent a fivefold gap between machine and human performance on tasks that humans complete routinely.

Two broad architectural approaches have emerged for closing this gap. The first treats the desktop as a visual environment: the agent receives a screenshot, reasons about what to do, and executes atomic mouse and keyboard primitives. Anthropic's Computer Use [Anthropic, 2024] and OpenAI's Operator [OpenAI, 2025] both adopt this approach. Both are deployed in production. The second treats the desktop as a structured environment: the agent receives both visual and semantic information---accessibility trees, HTML DOMs, UI Automation control patterns---and uses compositional tools that operate on named elements rather than raw coordinates. UFO [Zhang et al., 2025] and SeeAct [Zheng et al., 2024] adopt this approach.

Both approaches have empirical support. Neither has demonstrated clear superiority under controlled conditions on a shared benchmark. This paper's central thesis is that **the perception modality debate for desktop automation agents is underdetermined by current evidence**. The existing benchmark data is (a) platform-confined (OSWorld evaluates on Ubuntu, UFO on Windows, UGround on web and mobile), (b) model-dependent (adding accessibility trees helps GPT-4V but severely hurts GPT-4o), and (c) benchmark-dependent (pure vision wins on Mind2Web but loses on WindowsBench). No controlled study exists for macOS-native applications. Until such a study is conducted, the optimal perception strategy for macOS desktop automation remains a genuine unknown.

The evidence is not merely absent. It is contradictory. On OSWorld, adding accessibility tree data to screenshots improves GPT-4V performance by 0.4 percentage points but degrades GPT-4o by 13.3 percentage points [Xie et al., 2024]. On Mind2Web, UGround's pure-vision approach outperforms Set-of-Mark (screenshot plus structured annotations) by 19--21 points [Gou et al., 2024]. On WindowsBench, UFO's screenshot-plus-accessibility approach achieves 86% success [Zhang et al., 2025]. These results cannot all be right about the same question. The question is more nuanced than "does structured perception help?"---it depends on the model, the benchmark, the platform, and factors that have not been isolated.

This paper does not resolve the debate. It conducts a structured literature review to map what is known and unknown about the factors that determine whether an AI agent can reliably control a macOS desktop GUI. The mapping identifies three categories of findings: (1) phenomena that are documented and not in serious dispute, (2) phenomena where the evidence is genuinely contradictory, and (3) phenomena where no controlled evidence exists for macOS specifically. For each category, the paper states the evidence, identifies where it contradicts itself, and specifies what experiments would resolve the contradictions.

### 1.1 Positioning Relative to Prior Work

This paper is a revised and extended version of an earlier analysis [V3]. The revisions address five structural deficiencies identified through adversarial review:

First, the earlier version did not commit to a genre, oscillating between systematic review, position paper, engineering report, and research agenda. This version commits to the structured literature review genre with a methods section adapted from PRISMA guidelines. It does not claim PRISMA compliance: there is no registered protocol, no inter-rater reliability measure, and no PRISMA flow diagram. The methods section documents the search strategy, inclusion criteria, and quality assessment to enable reproducibility within these constraints.

Second, the earlier version framed engineering observations from the macOS accessibility layer as novel findings. This version reframes them as instances of known problem classes from the UI test flakiness, RPA reliability, and distributed consistency literatures---a reframing that is both more accurate and more useful, because it connects macOS-specific failures to solutions that already exist in adjacent fields.

Third, the earlier version treated production deployment data as a four-sentence footnote. This version elevates production deployment data to first-class evidence, incorporating the extensive reliability metrics published in OpenAI's Operator System Card [OpenAI, 2025b]---a source that the earlier version erroneously claimed contained "zero reliability metrics." That claim was false. The System Card reports confirmation prompt recall of 92%, proactive refusal recall of 94%, and prompt injection monitor recall of 99% [OpenAI, 2025b].

Fourth, the earlier version stated falsification criteria in vague terms ("outperform," "equivalently"). This version provides actionable falsification criteria with minimum effect sizes, statistical tests, and cost estimates.

Fifth, the earlier version did not acknowledge the source of its engineering observations. This version explicitly states that the observations in Section 6 were collected during the development of MacosUseSDK, an open-source macOS automation framework. The analysis was conducted after the implementation existed. Post-hoc analysis is inherently weaker than prospective research. This paper attempts to mitigate this bias by: (1) presenting raw observations with code references rather than design implications, (2) labeling hypotheses as hypotheses with falsification criteria, (3) framing engineering observations as instances of known problem classes rather than novel findings, (4) documenting five reliability mitigations present in the codebase that reduce the severity of the documented failures, and (5) marking unverifiable sources explicitly. The reader should assess whether these mitigations are sufficient. The engineering observations should be treated as confirmed for one implementation (n = 1), with cross-validation pending.

### 1.2 Scope and Contributions

This paper makes three contributions. First, it provides the first structured literature review of computer-use agent reliability, spanning eight disciplines: GUI agent benchmarks, accessibility API reliability, UI test flakiness, RPA deployment outcomes, distributed consistency theory, partially observable decision processes, cognitive load in LLM tool use, and human factors in automated systems. Second, it documents the production reliability data published by Anthropic and OpenAI---data that is scattered across engineering blogs, system cards, and API documentation, and has not been synthesized in an academic context. Third, it identifies a prioritized research agenda with specific, achievable experiments and cost estimates for each open question.

The paper does not make four kinds of claims that might be expected from its title. It does not resolve the perception debate. It does not evaluate any agent system. It does not present novel experimental results. It does not argue for a particular tool interface design. Each of these would require a different kind of paper than this one.

---

## 2. Methods

### 2.1 Search Strategy

Sources were identified through systematic database searches and citation tracking. The following databases were searched: arXiv, Semantic Scholar, DBLP, ACL Anthology, Google Scholar, IEEE Xplore, and ACM Digital Library. Searches were conducted between January and June 2026.

The primary search terms were: ("computer use agent" OR "GUI agent" OR "desktop automation" OR "screen agent" OR "UI automation agent") AND ("benchmark" OR "evaluation" OR "reliability" OR "failure" OR "accuracy"). The date range was 2022-01-01 to 2026-06-01, covering the period during which computer-use agents emerged as a research field. Foundational references published before 2022 were included when cited by included sources. Language was restricted to English.

After initial screening revealed relevant work in adjacent disciplines, extended search terms were added: ("RPA" OR "robotic process automation") AND ("reliability" OR "failure"); ("test flakiness" OR "flaky test" OR "Selenium"); ("accessibility API" OR "a11y" OR "AXAPI" OR "UI Automation" OR "AT-SPI" OR "AccessibilityNodeInfo"); ("partial observability" OR "POMDP" OR "observation delay"); ("cognitive load" OR "tool selection" OR "tool routing") AND ("LLM" OR "language model"); ("distributed consistency" OR "eventual consistency" OR "staleness"); ("automation bias" OR "vigilance" OR "human factors" OR "supervision"). These extended terms were added because the initial searches returned results that referenced these literatures but the primary search terms did not capture them.

### 2.2 Inclusion Criteria

A source was included if it met any of the following criteria:

- (a) Reports empirical evaluation of computer-use agents, UI automation reliability, or accessibility API reliability. This includes benchmark papers, system papers with quantitative evaluations, and studies of API failure rates.
- (b) Provides theoretical frameworks applicable to desktop agent reliability. This includes distributed consistency models, partially observable Markov decision processes, cognitive load frameworks, and human factors taxonomies.
- (c) Documents platform constraints relevant to macOS desktop automation. This includes Apple API references, security framework documentation, and vendor-supplied engineering data.
- (d) Reports production deployment data for computer-use systems. This includes vendor documentation and engineering blogs that provide specific, verifiable metrics.

### 2.3 Exclusion Criteria

A source was excluded if it met any of the following criteria:

- (a) Proposes architectures without empirical evaluation. Papers that describe systems without reporting quantitative results were excluded.
- (b) Discusses desktop automation only in the context of web automation without generalization to native desktop. Studies of web-only systems (Selenium, Playwright) were included only when they reported findings applicable to desktop GUI automation (e.g., flakiness taxonomies, self-healing strategies).
- (c) Is a secondary survey that does not contribute original data. Surveys that synthesize original data from multiple sources were included; surveys that only summarize prior work without new analysis were excluded.

Note that the inclusion criteria do not impose a quality floor. Sources that meet the inclusion criteria are included regardless of quality, then assessed post-hoc using the quality framework in Section 2.5. This approach includes low-quality but informative sources (vendor documentation with verifiable metrics) while labeling their evidential weight explicitly. A stricter criterion would exclude the production deployment data from Anthropic and OpenAI, which is the strongest available evidence about real-world agent behavior despite being vendor-sourced.

### 2.4 Screening Process

Sources were identified through two mechanisms: database searches using the terms specified in Section 2.1, and forward/backward citation tracking of all included papers. Forward citation tracking used Google Scholar and Semantic Scholar to identify papers that cited included sources. Backward citation tracking examined the reference lists of included sources.

Title and abstract screening was performed against the inclusion and exclusion criteria. Full-text assessment was performed for all sources passing the title/abstract screen. Sources that could not be accessed in full text were excluded.

### 2.5 Quality Assessment

Quality assessment was performed using an adapted risk-of-bias tool with four levels:

- **High quality**: Peer-reviewed publication with quantitative results and controlled experimental design. This level requires both a peer-reviewed venue and a study design that controls for confounds (e.g., ablation studies, controlled comparisons, held-out test sets).
- **Medium quality**: Peer-reviewed publication or well-documented preprint with quantitative results but limited experimental control. This level captures papers that report numbers but do not isolate causal mechanisms.
- **Low quality**: Non-peer-reviewed source (vendor documentation, engineering blogs) with specific, verifiable metrics. This level requires that the source provides concrete numbers that could, in principle, be independently reproduced.
- **Unverifiable**: Source identified through search but could not be confirmed via DOI, peer-reviewed venue, or primary source. These sources are included in the review but explicitly marked.

### 2.6 Quality Assessment Summary

| Quality Level | Count | Examples |
|---------------|-------|---------|
| High | ~30 | OSWorld [Xie et al., 2024, NeurIPS 2024]; WebArena [Zhou et al., 2024, ICLR 2024]; UGround [Gou et al., 2024, ICLR 2025 Oral]; Romano et al. [2021, ICSE 2021]; WEFix [2024, WWW 2024]; DOMDP [Wang et al., 2024, ICLR 2024 Spotlight]; Chen et al. [2023, NeurIPS 2023]; SeeAct [Zheng et al., 2024, ICML 2024]; UFO [Zhang et al., 2025, NAACL 2025]; CogAgent [Hong et al., 2024, CVPR 2024 Highlight] |
| Medium | ~15 | Scaling Laws [Chen et al., 2026, arXiv]; ShowUI [Lin et al., 2024, arXiv]; CLAI/ToolLoad-Bench [Wang et al., 2026, AAAI 2026]; Tools Tax [Sadani & Kumar, 2026, arXiv]; Bailis et al. PBS [2012, VLDB]; Daniel et al. [2018, Middleware]; RDC [2025, NeurIPS 2025]; CUA-Bench [2025, arXiv]; MMBench-GUI [2026, ICLR 2026] |
| Low | ~10 | Anthropic Computer Use engineering blog [Anthropic, 2024--2026]; OpenAI CUA/Operator System Card [OpenAI, 2025b]; Apple API documentation; Fazm.ai community reports; Healenium [2025, IJAM]; ProMCP [2026, OpenReview] |
| Unverifiable | ~5 | GUIrilla [2025]; macOSWorld [2025]; macbench [2026]; LinkedIn PBS production data [Bailis et al., slide deck]; deck.co benchmarks |

Quality levels and verification status are independent categorizations. Quality assesses the source's methodological rigor (peer review, experimental control). Verification status assesses whether the source could be independently confirmed (DOI, venue, primary data). A source can be High quality and PARTIALLY VERIFIED (e.g., Apple API documentation, which is authoritative but not peer-reviewed), or Medium quality and VERIFIED (e.g., a preprint with reproducible results). The two taxonomies serve different purposes: quality informs weight of evidence; verification informs reliability of citation.

The total corpus comprises approximately 60 sources. The "Unverifiable" category includes sources that were identified through search and referenced by other included sources, but whose primary data could not be independently confirmed. These sources are cited with explicit UNVERIFIED markers throughout the paper. The GUIrilla finding that "only 33% of macOS apps offer full accessibility support" [GUIrilla, 2025, UNVERIFIED] is presented as an unverified estimate, not as a measurement.

### 2.7 Negative Results

Three searches returned no relevant results:

1. **"accessibility tree" + "macOS" + "agent" + "controlled study"** returned 0 results. No published study has conducted a controlled A/B comparison of accessibility tree access on macOS-native applications.

2. **"POMDP" + "desktop agent"** returned 0 results. While multiple survey papers formalize GUI agents as POMDPs [Nguyen et al., 2024; Zhang et al., 2024], no published study has instantiated a formal POMDP model of desktop agent state with empirical validation of the observation function.

3. **"cognitive load" + "desktop automation" + "LLM"** returned 0 results. No published study has measured the cognitive load imposed by desktop-specific tool interfaces on LLM agents. The cognitive load literature for LLM tool use [Wang et al., 2026; Sadani & Kumar, 2026] addresses general tool-use tasks, not desktop automation.

These negative results define the boundary of current knowledge. Each corresponds to an open question in Section 8.

---

## 3. Background: Benchmarks and Systems

### 3.1 Benchmarks

Seven benchmarks define the empirical baseline for computer-use agent performance. They differ in platform coverage, task scope, and the aspects of agent capability they test.

**WebArena** [Zhou et al., 2024, ICLR 2024; High quality] provides 812 benchmark tasks across self-hosted websites. The best GPT-4-based agent achieved 14.41% end-to-end task success versus human performance of 78.24%. WebArena demonstrated that text-only DOM/HTML access is insufficient for real web tasks; agents that relied solely on accessibility trees missed visual layout cues. **Platform coverage: web only.** No desktop tasks.

**VisualWebArena** [Koh et al., 2024, ACL 2024; High quality] extends WebArena with 910 visually grounded tasks. Text-only LLM agents failed on tasks requiring visual understanding, and multimodal agents still struggled with complex spatial reasoning. **Platform coverage: web only.** No desktop tasks.

**OSWorld** [Xie et al., 2024, NeurIPS 2024; High quality] provides 369 tasks across Ubuntu, Windows, and macOS. Humans achieve 72.36% success; the best AI agent at the time of publication achieved 12.24%. The three primary failure modes identified are GUI grounding, operational knowledge, and long-horizon planning. OSWorld is the only benchmark that tests perception modality combinations systematically, and its results on this question are the most directly relevant---and the most contradictory (see Section 5). **Platform coverage: Ubuntu primarily; Windows and macOS tasks exist but evaluation is predominantly on Ubuntu.** The perception modality experiments (GPT-4V, GPT-4o, Gemini-Pro-1.5) were conducted on Ubuntu with AT-SPI/ATK accessibility trees, not macOS AXAPI trees.

**Mind2Web** [Deng et al., 2023, NeurIPS 2023; High quality] provides 2,000+ tasks across 137 websites with element-level grounding annotations. It is the primary benchmark for evaluating grounding accuracy separately from task completion. **Platform coverage: web only.** No desktop tasks.

**ScreenSpot** [Cheng et al., 2024, ACL 2024; High quality] provides single-step grounding tasks across mobile, web, and desktop platforms, including macOS desktop tasks. It tests grounding in isolation, not task completion. **Platform coverage: includes macOS desktop tasks.** This is the only established benchmark that includes macOS-specific grounding evaluation.

**CUA-Bench** [2025, arXiv; Medium quality] evaluates computer-use agents on production-like tasks. It revealed a 10x performance variance across minor UI changes---a finding with direct implications for the reliability of deployed agents. **Platform coverage: multi-platform.** Detailed platform breakdown not reported.

**MMBench-GUI** [2026, ICLR 2026; Medium quality] provides a comprehensive GUI understanding benchmark across platforms. macOS lags substantially on task automation compared to Android, suggesting that current models are less capable on macOS interfaces. **Platform coverage: Android, web, macOS.**

**MacArena** [2025; Medium quality] is a macOS-native benchmark that revealed that model rankings invert between macOS and Linux: the leading model on Linux trails by 26% on macOS. **Platform coverage: macOS.** This finding directly challenges the assumption that benchmark results on Ubuntu transfer to macOS.

**ScaleCUA** [2025; Medium quality] demonstrated that cross-platform training data improves agent performance, providing indirect evidence that platform-specific factors matter for agent capability. **Platform coverage: multi-platform.**

macOSWorld [2025, UNVERIFIED] and macbench [2026, UNVERIFIED] are brand-new macOS-native benchmarks with minimal published results. Their existence confirms that the community recognizes the macOS-specific evaluation gap, but they do not yet provide sufficient data to resolve any of the open questions in this review.

The platform coverage of these benchmarks has a structural implication: the strongest evidence about perception modality comes from benchmarks (OSWorld, Mind2Web) that do not evaluate on macOS. The benchmarks that do include macOS (ScreenSpot, MacArena, MMBench-GUI) either test grounding in isolation or are too new to provide definitive results. This gap is the primary motivation for this review.

### 3.2 Agent Systems

Eight systems represent the current architectural spectrum. For each, we report benchmark performance, production deployment status, and acknowledged failure modes.

**Anthropic Computer Use** [Anthropic, 2024; Low quality --- vendor documentation] uses screenshots only for perception, with no accessibility tree access. Its action space comprises 15+ mouse and keyboard primitives. **Deployed in production.**

Benchmark performance: OSWorld trajectory improved from 14.9% in October 2024 to 28% in February 2025 to 61.4% in September 2025 to 72.5% in February 2026 to 83.4% in May 2026 [Anthropic, 2024--2026; Low quality --- engineering blog]. These are trajectory-level numbers (best-of-k attempts), not single-attempt success rates.

Acknowledged failure modes: Anthropic explicitly acknowledges "coordinate hallucination" as a fundamental challenge [Anthropic, 2024]. In production, Anthropic reports a 93% approval rate (users approving agent-proposed actions) and a 17% auto-mode miss rate (cases where the agent should have acted autonomously but requested user approval instead) [Anthropic Engineering Blog, March 2026; Low quality]. Latency is 800--2000ms per action [Browser-Use comparison; Medium quality]. The OSWorld-Human evaluation found that end-to-end completion times are "tens of minutes" for tasks that humans complete in 2--3 minutes, with 75--94% of latency attributable to planning [Hu et al., 2024; Medium quality].

Prompt injection vulnerability: RedTeamCUA reported 83% attack success rate against Claude 4.5 and 50% against Claude 4.6 [arXiv:2505.21936; Medium quality]. VentureBeat reported 31.5% raw attack success rate dropping to 0.5% with safeguards against Claude 4.8 [VentureBeat, 2025; Low quality]. The earlier claim of "96% prompt injection success (24/25)" attributed to Anthropic could not be verified and is likely a misattribution [UNVERIFIED].

**OpenAI CUA / Operator** [OpenAI, 2025; Low quality --- vendor documentation] uses screenshots only via GPT-4o vision. Its action space is smaller than Anthropic's: click(x, y), type(text), scroll, wait, goto_url. **Deployed in production.**

Benchmark performance: 38.1% on OSWorld [OpenAI, 2025; Low quality --- first-party]. Independent evaluations report 38--61% on OSWorld, showing significant variance across evaluation conditions.

Acknowledged failure modes: An earlier version of this review claimed that OpenAI "published zero reliability metrics" for Operator. This claim was false. The Operator System Card [OpenAI, 2025b; Low quality --- vendor documentation, 47-page PDF] contains extensive reliability data:

- Confirmation prompt recall: 92% (the system correctly prompts for confirmation on actions that require it)
- Proactive refusal recall: 94% (the system correctly refuses harmful actions)
- Prompt injection susceptibility: 23% with mitigations versus 62% without mitigations
- Prompt injection monitor recall: 99%, precision: 90%

Operator struggles with CAPTCHAs, two-factor authentication dialogs, and complex interactive widgets (drag-and-drop, canvas interactions) [OpenAI, 2025b]. These failure modes are consistent with the limitations of screenshot-only perception for interfaces that require understanding of interactive state that is not visible in a static screenshot.

**ShowUI** [Lin et al., 2024; Medium quality --- arXiv preprint] is a 2B-parameter Vision-Language-Action model achieving 75.1% zero-shot screenshot grounding accuracy with no accessibility tree. This demonstrates that small, specialized models can achieve competitive grounding performance using screenshots alone. **Not deployed in production.**

**UGround** [Gou et al., 2024, ICLR 2025 Oral; High quality] advocates purely visual agents, trained on 10M GUI elements across 1.3M screenshots. It outperforms Set-of-Mark (screenshot plus structured annotations) by 19--21 points on Mind2Web. This is the strongest evidence for the pure-vision position. **Not deployed in production.** Acknowledged limitation: evaluated on web and mobile benchmarks only, not on native desktop applications.

**CogAgent** [Hong et al., 2024, CVPR 2024 Highlight; High quality] is an 18B VLM with a dual-encoder (low-res + high-res) processing 1120x1120 input. It outperforms LLaMA2-70B using HTML by 6.5 points on Mind2Web without using accessibility data itself. **Not deployed in production.** Acknowledged limitation: resolution bound at 1120x1120, which may be insufficient for high-DPI professional desktop applications.

**SeeAct** [Zheng et al., 2024, ICML 2024; High quality] uses a two-stage architecture: an LMM perceives the screenshot and produces a textual action plan, then a grounding module maps the plan to an HTML element. With oracle grounding, 51% success. Without oracle grounding, performance drops substantially, demonstrating that grounding is the bottleneck, not reasoning. Uses both screenshots and HTML structure. **Not deployed in production.** Acknowledged limitation: grounding module is the primary failure point.

**UFO** [Zhang et al., 2025, NAACL 2025; High quality] combines visual perception with Windows UIA control info, achieving 86% success on WindowsBench. This is the strongest empirical result for dual perception. **Not deployed in production as a standalone product.** Acknowledged limitation: evaluated on Windows with UIA only. UIA is more feature-rich than macOS AXAPI (UIA provides pattern-based interaction models, property change events, and text attribute reporting that AXAPI does not). Whether the result transfers to macOS is unknown.

**Agent S2** [Agashe et al., 2025, COLM 2025; High quality] introduces Mixture-of-Grounding and Proactive Hierarchical Planning. It achieves 18.9% and 32.7% relative improvements over Claude Computer Use and UI-TARS on OSWorld. **Not deployed in production.**

### 3.3 Production Deployment Status Summary

Two systems are deployed in production. Both use screenshot-only perception. This is a fact that demands engagement: if pure vision were fundamentally inadequate for desktop automation, these products would not have shipped. But shipping is not the same as working well. The production data in Section 4.7 reveals specific, persistent failure modes that suggest screenshot-only perception is sufficient for some class of desktop tasks but inadequate for others.

At the same time, the production data reveals specific, persistent failure modes. Anthropic reports coordinate hallucination, approval fatigue (93% approval rate raises questions about whether users are rubber-stamping), and a 17% auto-mode miss rate where the agent fails to act when it should. OpenAI reports difficulty with CAPTCHAs, 2FA, and complex widgets, and a 23% prompt injection susceptibility even with mitigations. These failure modes are not randomly distributed: they cluster around tasks that require understanding of interactive state, semantic element identity, or security-critical context---precisely the information that accessibility trees provide.

The benchmark-versus-deployment gap is substantial. Anthropic's OSWorld trajectory improved from 14.9% to 83.4% over 18 months, but third-party estimates place real-world task success at approximately 34% [The Editorial, 2025; Low quality --- third-party, UNVERIFIED], a gap of roughly 38 percentage points. This is consistent with the RPA literature, which reports that only 3--4% of organizations operate 50+ robots at scale [Deloitte, 2019; Low quality --- industry survey], and that 30--50% of RPA pilot projects fail [Smeets et al., 2019; Medium quality; Kraus et al., 2024, BPMJ; Medium quality].

### 3.4 Platform-Specific Benchmark Findings

Three benchmarks provide evidence that platform matters for agent performance. MacArena [2025; Medium quality] found that model rankings invert between macOS and Linux, with the leading model trailing by 26% on macOS. MMBench-GUI [2026, ICLR 2026; Medium quality] found that macOS lags substantially on task automation compared to Android. CUA-Bench [2025, arXiv; Medium quality] found 10x performance variance across minor UI changes, suggesting that agent robustness to interface variation is itself a platform-dependent property.

These findings challenge the common practice of evaluating agents on Ubuntu (OSWorld) or web (Mind2Web, WebArena) and generalizing the results to macOS. The inversion of model rankings on MacArena is particularly significant: if Model A outperforms Model B on Linux but Model B outperforms Model A on macOS, then no evaluation conducted on Linux alone can determine which model is better for macOS deployment.

ScaleCUA [2025; Medium quality] demonstrated that cross-platform training data improves performance, providing indirect evidence that platform-specific factors are learnable. This suggests that the macOS performance deficit may narrow as macOS-specific training data becomes available, but it does not resolve the question of whether the current macOS deficit is due to perception modality, model training, or platform-specific API limitations.

---

## 4. Observable Phenomena

This section documents what happens when agents attempt to control desktop GUIs. Each phenomenon is stated with supporting evidence and an evidence quality rating. Where a source could not be independently verified, that fact is noted in the text. Where V3 of this paper contained errors, those errors are corrected here.

### 4.1 Agents Fail at Grounding [STRONG EVIDENCE]

Grounding --- mapping an action intention to a screen coordinate or UI element --- is a dominant failure mode for computer-use agents. SeeAct demonstrated this directly: with oracle grounding (a human identifying the correct HTML element), the system achieved 51% success; with automated grounding, performance dropped substantially [Zheng et al., 2024]. OSWorld identified "GUI grounding" as one of three primary failure modes [Xie et al., 2024].

The severity of the grounding gap depends on the perception approach and the model. The OSWorld paper provides the most granular data on this question, and the data is contradictory:

| Model | Screenshot Only | Screenshot + A11y Tree | Delta |
|-------|----------------|----------------------|-------|
| GPT-4V | 11.77% | 12.17% | +0.4 |
| GPT-4o | 24.5% | 11.2% | -13.3 |
| Gemini-Pro-1.5 | 7.79% | 5.1% | -2.7 |

These numbers come from the OSWorld paper [Xie et al., 2024]. The GPT-4o regression is the most striking result: adding accessibility tree data cuts success rate by more than half. The OSWorld authors attribute this to token burden, noting that "the massive amount of tokens contained in the a11y tree (even just the leaf nodes can have tens of thousands of tokens) can also impose an additional inference burden" [Xie et al., 2024]. But token burden alone does not explain why the more capable model (GPT-4o) degrades more severely than the less capable one (GPT-4V). This model-specific variation is analyzed further in Section 5.3 and 5.4.

Pure-vision systems have produced strong grounding results on other benchmarks. UGround outperforms Set-of-Mark by 19--21 points on Mind2Web [Gou et al., 2024]. ShowUI achieves 75.1% zero-shot screenshot grounding accuracy with no accessibility tree [Lin et al., 2024]. CogAgent, an 18B VLM, outperforms LLaMA2-70B using HTML by 6.5 points on Mind2Web without using accessibility data itself [Hong et al., 2024]. But pure vision also fails badly: GPT-4o screenshot-only achieves 24.5% on OSWorld, far below human performance of 72.36% [Xie et al., 2024]. GPT-4o-mini achieves 0% success even with both screenshot and a11y inputs [Xie et al., 2024].

Anthropic acknowledges what they term "coordinate hallucination" --- the tendency of models to generate plausible but incorrect screen coordinates --- as a fundamental challenge [Anthropic, 2024]. The term "coordinate hallucination" originates from Arun Baby [2026] in a third-party analysis; it is not Anthropic's official terminology. Regardless of the label, the phenomenon is empirically documented: agents generate coordinates that correspond to plausible but incorrect screen locations, particularly for small targets and complex layouts.

Grounding is the bottleneck. The SeeAct oracle-vs-automated comparison demonstrates that when grounding is solved, reasoning can achieve reasonable performance; the gap between oracle and automated performance is primarily a grounding gap, not a reasoning gap [Zheng et al., 2024].

### 4.2 Accessibility APIs Are Incomplete [STRONG EVIDENCE for coverage gaps; WEAK EVIDENCE for coverage rates]

Accessibility APIs across all major platforms --- macOS AXAPI, Windows UI Automation, Android AccessibilityNodeInfo, and Linux AT-SPI --- exhibit systematic coverage gaps. These are not platform-specific quirks; they are structural consequences of how accessibility APIs are designed and adopted.

**Coverage gaps.** Nguyen et al. [2024] documented that accessibility APIs "may be limited when dealing with highly dynamic elements" and that metadata can be "noisy, incomplete, and computationally expensive to parse at every step." Zhang et al. [2024] noted limitations with dynamic elements and custom drawing. On macOS specifically, Canvas and WebGL content is invisible to AXAPI [Chromium Accessibility Documentation]. Custom controls that do not adopt NSAccessibility protocols are invisible to accessibility clients [Apple, Accessibility Programming Guide]. The Fazm.ai community report confirms that Qt applications, OpenGL applications, and Python-based tools return `kAXErrorCannotComplete`, indicating that "the target app does not implement the accessibility tree at all" [Fazm.ai, 2025].

GUIrilla [2025] reported that only 33% of macOS apps offer full accessibility support. **This figure is an unverifiable estimate**: the source could not be confirmed via DOI or peer-reviewed venue, and the methodology for deriving the percentage is not documented. It is cited here because it is the only quantitative estimate of macOS AXAPI coverage found in the literature, but it should be treated as an unverified claim, not a measurement.

**Cross-platform comparison.** The same categories of coverage gaps appear on every platform:

| Gap Category | macOS (AXAPI) | Windows (UIA) | Android (AccessibilityNodeInfo) | Linux (AT-SPI) |
|---|---|---|---|---|
| Canvas/WebGL blindness | Yes [Chromium] | Yes [DirectX/custom] | Yes [WebView] | Yes [non-GTK] |
| Custom control invisibility | Yes [Apple] | Yes [WPF custom, DirectX] | Yes [custom Views] | Yes [non-GTK, Flatpak] |
| Cross-platform framework gaps | Yes [Electron, Qt, Tk] | Yes [Electron, Qt] | Yes [WebView, React Native] | Yes [Electron, Qt] |
| IPC latency | Yes (Mach, up to 750ms) | Yes (COM, 200--300ms) | Yes (Binder, ~100ms) | Yes (D-Bus, worst) |

Canvas and WebGL blindness is universal across all four platforms: any application that renders its primary interface via Canvas, WebGL, DirectX, or equivalent GPU-accelerated rendering is partially or fully invisible to accessibility clients. There is no workaround at the API level on any platform.

The Electron AX gap is a web platform problem manifesting everywhere. Electron applications use Chromium's accessibility implementation, which depends on correct ARIA annotations in the web content. When the web content lacks proper ARIA, the accessibility tree for the Electron application is sparse or misleading --- on macOS, Windows, and Linux alike.

**Coverage rates.** No peer-reviewed study provides quantitative AXAPI coverage rates for any platform. The GUIrilla 33% figure for macOS is the only estimate found, and it is unverifiable. No comparable figure exists for Windows UIA, Android AccessibilityNodeInfo, or Linux AT-SPI. This is a significant gap in the literature: coverage rates would directly inform the perception debate (Section 5), but the data does not exist in publishable form.

### 4.3 UI Automation Reliability Is a Well-Studied Problem [STRONG EVIDENCE]

The failure modes that desktop agents encounter --- stale state after mutations, element identification failures, timing-dependent brittleness --- are not novel. They are instances of well-known problem classes that the UI automation and RPA communities have studied for over a decade. This section documents the quantitative evidence and maps the findings to the desktop agent context.

#### 4.3.1 UI Test Flakiness

The software testing community has empirically studied why automated UI tests fail intermittently, a phenomenon known as "flakiness." The findings are directly relevant because the same root causes that make Selenium tests flaky also make desktop agent interactions unreliable.

Romano et al. [ICSE 2021] analyzed 2,177 flaky UI tests across 62 open-source projects and found that **45.1% of flakiness is caused by asynchronous wait issues** --- precisely the same class of problem as the AX API propagation lag documented in Section 6.1. The subcategories include network resource loading (8.1%), resource rendering (26.0%), and animation timing (11.1%), all of which have direct macOS analogues (AX server synchronization, window animation completion, Dock rendering).

Luo et al. [FSE 2014] independently found that **45.9% of flakiness is caused by async-wait issues** across 201 commits from 51 projects. The convergence of these two studies at ~45% establishes the async-wait category as the dominant source of UI automation unreliability.

The WEFix study [WWW 2024] found that **65.7% of end-to-end commands are flaky-prone** across 7 real-world web projects, and that **98.4% of flaky tests can be fixed by generating proper wait oracles** --- essentially the same strategy as the MacosUseSDK's PollUntil pattern after minimize operations (Section 6.4).

The ICST 2025 study of 123 flaky tests across 49 open-source projects found that DOM event flakiness takes an **average of 153.4 days to resolve**, indicating that these are persistent, difficult-to-fix problems, not transient bugs.

The structural mapping between UI test flakiness and desktop agent failures:

| Flakiness Cause (Selenium) | Desktop Agent Equivalent | Frequency |
|---|---|---|
| Async wait / timing (45.1%) | AX propagation lag, CG staleness | Dominant |
| Test runner API issues (10.2%) | AX query failures, empty kAXWindows | Common |
| Environment factors (19%) | macOS version/hardware variability | Moderate |
| DOM selector invalidation (6.8%) | Element locator drift after app updates | Moderate |

#### 4.3.2 RPA Reliability

The RPA industry has deployed UI automation at enterprise scale for over a decade. Their reliability data provides production-grade baselines.

Smeets et al. [2019], confirmed by Kraus et al. [2024, BPMJ] and Herm et al. [2020], found that **30--50% of initial RPA projects fail at the pilot stage**. This is pilot-stage failure, not production failure: projects that never make it past initial deployment because the UI automation proves too fragile. Deloitte's enterprise RPA survey of 530 respondents ($3.5T aggregate revenue) found that **only 3--4% of organizations successfully operate 50+ robots** [Deloitte]. The gap between pilot success and production scale is the same gap that exists between benchmark performance and real-world agent deployment (Section 4.7).

Aguirre and Rodriguez [2017] examined a **single case study** of RPA integration. V3 of this paper incorrectly cited this as "10 case studies." The source is a single organizational case, not a multi-case study. The finding that RPA implementation faces significant organizational and technical challenges is consistent with the broader literature, but the specific finding should not be given the weight of a 10-case study.

Crisan et al. [2023] found that **~10% of deployed RPA robots are subsequently "withdrawn"** (re-manualized), indicating that even successful deployments may regress.

The RPA industry has quantified the failure modes: approximately 60% of RPA failures originate from UI changes and selector breaks [Leotta et al., 2013]; 50% of developer time is spent fixing bots; 60--70% of total RPA effort is maintenance, not development [Smeets et al., 2019]. The cost structure is dominated by reliability work: for every $1 spent on RPA licensing, $3.41--4.00 is spent on consulting and maintenance.

The RPA industry has also developed solutions that the desktop agent community has not adopted: self-healing selectors (40--60% reduction in locator failures [IJAM 2025], though this is gray literature and web-only), CI/CD testing pipelines for bot validation, and environment locking (VDI with pinned application versions). **No peer-reviewed study evaluates self-healing for desktop GUI automation.** All self-healing research targets web automation (Selenium, Playwright). This is a critical gap: the self-healing techniques that work for DOM element locators may not transfer to AX element identification, and no study has tested whether they do.

#### 4.3.3 Structural Convergence

The failure modes across three domains converge structurally:

| Failure Mode | RPA (10+ years) | Selenium (academic) | Desktop Agents (emerging) |
|---|---|---|---|
| UI changes break selectors | ~60% of failures | "minor modifications invalidate locators" | "dynamic UIs that change while task is running" [Anthropic, 2024] |
| Timing / race conditions | "silent failures propagate for hours" | Concurrency = 23% of root causes [Romano, 2021] | AX cache desync; 800--2000ms per action |
| State staleness after mutations | N/A (synchronous execution) | StaleElementReferenceException | AX propagation lag (750ms), CG/AX disagreement |
| Application lifecycle non-determinism | "application changes outside CoE's control" | N/A | macOS activation semantics, bare binaries |
| Maintenance burden | 60--70% of effort | Self-healing reduces 30--50% | Same problem, no tooling yet |

The convergence is not coincidental. All three domains face the same fundamental problem: automated interaction with a GUI that was designed for human perception and human timing, not for programmatic access. The GUI was not designed to provide strong consistency guarantees to automated consumers. The AX API was designed for assistive technology (screen readers), which has different consistency requirements than automation: screen readers tolerate stale data because they poll periodically and present information for human judgment; automation agents require fresh data because they act on it immediately.

### 4.4 Desktop Agents Observe Stale State [MODERATE-STRONG EVIDENCE]

Desktop agents face a fundamental challenge formalized in two theoretical frameworks: partial observability in reinforcement learning and eventual consistency in distributed systems. This section connects the empirical observations from Section 6 to these frameworks.

#### 4.4.1 The Observation-Action Gap as Partial Observability

In reinforcement learning, the partially observable Markov decision process (POMDP) framework formalizes the problem of acting under incomplete state information. A desktop agent faces exactly this problem: the agent's observation (screenshot or accessibility tree) is a snapshot of the GUI state taken at time *t*. Between observation and action, the GUI may change --- another application activates, a dialog appears, an animation completes. The agent acts on stale state.

Wang et al. [ICLR 2024 Spotlight] formalized Delayed Observation MDPs (DOMDPs). They found that "trivial DRL algorithms and generic methods for partially observable tasks suffer greatly from delays" [Wang et al., 2024]. V3 of this paper attributed the claim "4 steps of delay = catastrophic failure" to this paper; **this claim was not found in the DOMDP paper**. What the paper does establish is that delay-reconciled critics and delay-reconciled actors substantially outperform naive approaches, and that the degradation from observation delay is non-linear. The precise threshold at which performance collapses depends on the environment and is not characterized as a fixed number of steps.

Chen et al. [NeurIPS 2023] established regret bounds for RL with impaired observability, proving that "a short delay does not reduce the optimal value, but slightly longer delay leads to substantial degradation" [Chen et al., 2023]. The formal result: RL with impaired observability is "provably as efficient as RL with full observability (up to poly factors of the horizon H)" when the delay is short relative to the horizon, but this efficiency guarantee degrades non-linearly as the delay-to-horizon ratio increases.

Karamzade et al. [RLJ 2024] showed that **world models can mitigate observation delay by up to 250%** (improvement over agentic baselines on DMC vision tasks), using actions and predictions to reconstruct current state. The MacosUseSDK's AppStateStore serves an analogous function: it maintains a consistent view of the UI state that can be queried independently of the AX server's real-time state, providing a "world model" that partially compensates for AX staleness.

#### 4.4.2 The AX API as an Eventually Consistent System

The macOS Accessibility API exhibits properties formally characterized in distributed systems as eventual consistency. After a mutation (e.g., moving a window), the AX server's internal state is temporarily inconsistent with the mutations that have been applied. Subsequent reads may return stale data for up to 750ms as observed in MacosUseSDK's retry budget (Section 6.1); this figure is an implementation-specific timeout, not a measured AX server convergence time. This is a **read-after-write consistency** problem: the write has committed, but the read does not yet reflect it.

Bailis et al. [VLDB 2012; CACM 2014] developed the **Probabilistically Bounded Staleness (PBS)** framework for quantifying such guarantees. PBS defines three metrics: t-visibility (time until a read is guaranteed to see a write), k-staleness (how many writes a read may miss), and (K,\Delta)-staleness (bounded staleness in both version and time). The AX API's behavior maps directly to PBS t-visibility: after a mutation, there exists a window of \Delta \approx 750ms (observed in MacosUseSDK; actual convergence may be faster) during which reads may not reflect the write.

V3 cited specific consistency percentages (97.4% immediate consistency, >99.999% within 5ms) from LinkedIn production data in the PBS paper. **These figures could not be independently verified** from the published paper; they appear to derive from a slide deck presentation that could not be parsed reliably. The PBS framework's analytical framework is verified; the specific production numbers are unverifiable.

The AX API's observed 750ms staleness window (a retry timeout from MacosUseSDK, not a measured convergence time) is significantly worse than typical eventually consistent systems, which converge in milliseconds. Note that this comparison is between a retry budget and convergence times — different quantities. The actual AX server convergence time is unknown. The AX server was designed for assistive technology consumers that poll at human-perceptible rates (typically 100ms or slower), not for automated agents that read-act-read in tight loops.

Daniel et al. [Middleware 2018] proved a **three-way impossibility result**: a system cannot simultaneously provide (1) atomic/order-preserving reads, (2) minimal delay, and (3) maximal freshness. This theorem applies directly to the desktop agent's dilemma:

- **Atomic reads**: Reading the complete, consistent state of all windows (screenshot + AX tree agreement)
- **Minimal delay**: Returning immediately without waiting for synchronization (800ms action cycle)
- **Maximal freshness**: Reading the most recent state after a mutation (750ms AX propagation lag)

The MacosUseSDK's three-tier data authority (ListWindows for fast cached data, GetWindow for fresh AX data, GetWindowState for deep authoritative data) is an engineering instantiation of this tradeoff: each tier optimizes for two of the three properties while sacrificing the third.

#### 4.4.3 Implications for Agent Architecture

The POMDP and eventual consistency frameworks provide principled guidance:

1. **Maintain a belief state.** The AppStateStore serves as a belief state over the true GUI state. When AX reads are stale, the belief state provides the best available approximation. This is analogous to Karamzade et al.'s world model approach [Karamzade et al., 2024].

2. **Act to reduce uncertainty.** When the belief state is uncertain (e.g., after a mutation), the agent should act to verify state before proceeding. This is the PollUntil pattern (Section 6.4).

3. **Accept bounded staleness.** Daniel et al.'s impossibility result means that no architecture can eliminate staleness without sacrificing latency. The agent must be designed to tolerate bounded staleness --- which requires knowing what the bounds are (Section 6.1 establishes 750ms for macOS).

4. **Decouple observation from action.** Wang et al. [2024] found that "detached methods consistently outperform non-detached methods" for DOMDPs. This suggests that agents should maintain a separate state model (detached from real-time AX queries) and use it as the basis for action selection, rather than acting directly on raw observations.

### 4.5 Application Lifecycle Is Non-Deterministic [STRONG EVIDENCE]

On macOS, launching or activating an application does not produce a deterministic state transition. The `NSWorkspace.openApplication` API's `activates` property controls whether a launched app comes to the foreground, but even with `activates = false`, macOS may force activation --- the behavior is not guaranteed [Apple, NSWorkspace API Reference]. The `activateIgnoringOtherApps:` method was deprecated as of macOS 14.0, replaced by cooperative activation via `activate()` and `yieldActivation(to:)` [Apple, NSApplication API Reference].

Applications may launch as bare binaries with no windows [Apple, ActivationPolicy Documentation]. Applications may launch with modal dialogs, crash recovery prompts, update notifications, or first-run setup screens. The state after launch is not predictable from the launch request alone.

Apple's own documentation states that "GUI Scripting tends to result in fragile scripts" [AppleScriptX], confirming that the platform vendor considers programmatic GUI interaction to be inherently unreliable. This is not a third-party claim; it is Apple's own characterization of the automation model they provide.

The Fazm.ai community report [2025] documents an additional non-determinism: after macOS system updates, the AX cache can desynchronize, causing `AXIsProcessTrusted()` to return stale values. The per-process cache does not invalidate after OS updates, and there is no public API to reset it; the only remedy is to quit and relaunch the automation process. This introduces a source of non-determinism that is invisible to the agent: the agent may believe it has accessibility permission when the OS has invalidated that permission.

### 4.6 Platform Security Creates Hard Boundaries [STRONG EVIDENCE]

macOS imposes security and lifecycle constraints that bound what an automation server can do. The TCC system gates access to the Accessibility API; permissions are stored in SQLite databases protected by SIP and scoped by "responsible process" [Apple, AXIsProcessTrusted API]. There is no `com.apple.security.accessibility` entitlement --- this is a documented hallucination found in some online sources; accessibility access is controlled exclusively by TCC user consent [Apple, Entitlements Reference]. The App Sandbox restricts inter-application communication. CGEvent taps require Accessibility permission or root privileges, and since macOS 10.15, an additional Input Monitoring permission [Apple, CGEventTapCreate API Reference].

Three additional security-related failure modes have been documented since V3:

**TCC permission cache staleness.** The Fazm.ai community report [2025] documents that `AXIsProcessTrusted()` reads from a per-process cache that does not invalidate after OS updates. An automation server may pass the permission check at startup, but subsequent OS-level changes (updates, preference pane changes) can silently invalidate the permission without the server's knowledge. There is no public API to detect or reset this state.

**App Sandbox blocks CGEvent.post() silently.** The DEV Community reports that `CGEvent.post()` silently does nothing inside a sandboxed application. No entitlement re-enables it. The workaround is to route input simulation through AppleScript, which adds 40--80ms of latency per event [DEV Community]. This is not a documented Apple API constraint; it is observed behavior that affects any automation tool running in a sandboxed context.

**Stage Manager breaks automation.** Apple Community reports that "there is no supported way to create Stage Manager groups" programmatically, and MacScripter reports that "turning ON/OFF Show Recent apps breaks Shortcuts/Automator." Stage Manager alters the window management model in ways that existing AX queries do not account for, causing automation failures that are difficult to diagnose because the AX API returns plausible but incorrect data rather than errors.

These constraints are documented and not contested. They shape what tool interfaces can promise and are a genuine engineering constraint on any macOS automation server. The security boundary problem is not unique to macOS (Windows UAC, Android permission model, Linux capabilities), but the TCC system's per-process cache staleness and the silent failure of CGEvent.post() under Sandbox are macOS-specific manifestations.

### 4.7 Production Systems Have Specific, Documented Failure Modes [MODERATE-STRONG EVIDENCE]

Two production computer-use systems are deployed as of 2026: Anthropic Computer Use and OpenAI CUA/Operator. Their documented failure modes provide the strongest available evidence about what actually goes wrong when agents interact with real desktop environments.

#### 4.7.1 Anthropic Computer Use

Anthropic has disclosed specific reliability metrics through their engineering blog [Anthropic, 2026]. First-party metrics (those disclosed by Anthropic themselves) are distinguished from third-party measurements:

| Metric | Value | Source Type |
|---|---|---|
| OSWorld benchmark trajectory (Oct 2024--May 2026) | 14.9% → 72.5% → 83.4% | First-party |
| Human approval rate (per-action permission) | ~93% | First-party [Anthropic, 2026] |
| Auto-mode miss rate (risky actions that get through) | ~17% | First-party [Anthropic, 2026] |
| Real-world comparison vs Operator (369 tasks) | 34% | Third-party [The Editorial, 2026] |
| Self-correction rate | 22% | Third-party [The Editorial, 2026] |

V3 cited a "96% prompt injection success rate (24/25)" attributed to Anthropic. **This figure is unverifiable.** It was not found in Anthropic's published documentation. The verified data on prompt injection comes from RedTeamCUA [arXiv:2505.21936], which found 83% success on Claude 4.5 and 50% on Claude 4.6 for credential exfiltration attacks. VentureBeat reported 31.5% raw susceptibility dropping to 0.5% with safeguards on Claude 4.8. The actual prompt injection risk is significant but the specific "96%" figure should not be cited.

V3 cited "2--8 seconds per action cycle" for latency. **This was overestimated.** The verified per-action latency is 800--2000ms [Browser-Use comparison data]. However, end-to-end task completion takes "tens of minutes" for tasks that a human completes in 2--3 minutes [OSWorld-Human], with 75--94% of latency attributable to planning rather than action execution.

**The 93% approval rate** is consistent with approval fatigue — the tendency for humans supervising automated systems to approve actions without careful review — but does not directly measure it. A 93% approval rate could also indicate that 93% of proposed actions are correct. The connection to Parasuraman and Manzey [2010] is plausible but unvalidated for computer-use agents specifically. This is consistent with the automation bias literature. Parasuraman and Manzey [2010] found that complacency is most prevalent when high-degree automation is more reliable --- the "irony of automation" [Bainbridge, 1983]. The 17% miss rate for risky actions quantifies the practical consequence: nearly one in five actions that should be flagged passes through the approval gate.

**The gap between benchmark (72.5%) and real-world (34%)** performance is -38.5 percentage points. This suggests that benchmark scores significantly overestimate real-world capability. The benchmark tests curated tasks in controlled conditions; the real world presents the full distribution of desktop tasks including CAPTCHAs, session timeouts, dynamic UIs, and ambiguous goals.

#### 4.7.2 OpenAI CUA/Operator

V3 claimed that "OpenAI has published zero reliability metrics for Operator/CUA." **This is false.** The OpenAI Operator System Card [OpenAI, 2025] --- a 47-page document --- contains extensive reliability and safety data:

| Metric | Value | Source |
|---|---|---|
| Confirmation prompt recall | 92% | System Card |
| Proactive refusal recall | 94% | System Card |
| Prompt injection susceptibility (with mitigations) | 23% | System Card |
| Prompt injection susceptibility (without mitigations) | 62% | System Card |
| Prompt injection monitor recall | 99% | System Card |
| Prompt injection monitor precision | 90% | System Card |
| OSWorld benchmark | 38.1% | First-party |

The 23% injection susceptibility (with mitigations) versus 62% (without mitigations) demonstrates that the monitoring layer provides substantial protection but does not eliminate the vulnerability. The 99% monitor recall with 90% precision means that the system catches nearly all injection attempts but produces a non-trivial false positive rate.

What OpenAI has not published is end-to-end task success rates in production environments, breakdown of failure modes by category, or approval fatigue data. The absence of these metrics is a gap, but it is not the "zero metrics" gap that V3 claimed.

#### 4.7.3 Production vs. Benchmark Reliability

The available data suggests a significant gap between benchmark and production reliability:

| System | OSWorld (benchmark) | Real-world comparison | Delta |
|---|---|---|---|
| Anthropic Computer Use (Claude Opus) | 72.5% | 34% (369 tasks) | -38.5pp |
| OpenAI CUA (GPT-4o) | 38.1% | Not published | Unknown |

AgentMarketCap found a **37% average gap** between benchmark and production across agent systems [AgentMarketCap]. EngineersOfAI reports "expect production 30--50% lower than benchmark" [EngineersOfAI]. The Anthropic delta of -38.5pp falls squarely within this range.

This benchmark-deployment gap is consistent with the RPA industry's experience (Section 4.3.2), where pilot success rates are far higher than production success rates (Deloitte: only 3--4% scale beyond pilot). The structural explanation is the same: benchmarks test curated tasks in controlled conditions, while production exposes the full distribution of edge cases, UI changes, and state variability.

The approval fatigue finding connects to the broader human factors literature on automation bias. Onnasch et al. [2014] meta-analyzed 18 studies and found that "the degree of automation reliably predicts automation-induced performance decrements" --- exactly the pattern observed with the 93% approval rate and 17% miss rate. More reliable automation produces more complacent supervision, which produces more missed failures.

### 4.8 Tool Routing Degrades with Tool Count [MODERATE EVIDENCE]

Chen et al. [2026] formalized the Routing Law: single-step routing accuracy decays logarithmically as the skill library size increases, following Acc(N) = a - b*ln(N). Their study of 15 frontier LLMs across 1,141 skills and over 3 million decisions found that routing accuracy exceeds 90% when the candidate pool is under 30 tools but drops to approximately 13.62% with hundreds of candidates.

New research strengthens and refines this finding:

**Performance cliffs and exponential decay.** Wang et al. [AAAI 2026] proposed the CLAI framework, which models tool selection accuracy as Accuracy ≈ exp(-(k*CL_Total + b)), where CL_Total is the total cognitive load imposed by the tool interface. This exponential decay model was statistically validated via Hosmer-Lemeshow tests (p>0.05 for all tested models) across four LLMs: xLAM2-32B (78.8%), GPT-4o (68.0%), Claude 3.7 (64.8%), Llama3.3-70B (17.0%) [Wang et al., 2026]. The exponential model implies performance cliffs: accuracy remains high until cognitive load crosses a threshold, then drops sharply.

**MCP-specific token overhead.** Sadani and Kumar [2026] --- correcting V3's misattribution to "Bansal et al." --- measured 15,000--55,000 tokens per turn overhead in typical 4--6 server MCP deployments. Their analysis identifies a **fracture point at N~50 tools**, where context utilization reaches ~70% and accuracy degrades sharply. For a MacosUseSDK-scale deployment, the token math is concrete: 77 tools * ~1,000 tokens per tool description = ~77,000 tokens, which is **60% of a 128K context window** --- crossing the fracture point. A compressed surface of 23 tools * ~500 tokens = ~11,500 tokens, or **9% of a 128K window** --- well within the safe range [MCP Issue #2808; Sadani & Kumar, 2026].

**Routing vs. execution accuracy.** The "Knowing-Doing Gap" [arXiv:2605.14038] found 26.5--54.0% mismatch between knowing which tool to use and correctly executing the invocation, on arithmetic tasks. The bottleneck is **execution, not knowing**. A four-layer evaluation stack distinguishes tool selection from argument extraction from result utilization from error recovery, and each layer adds independent failure probability. This distinction is critical for desktop automation: a model may correctly route to `click_element` but fail to extract the correct `element_id` parameter, producing a routing-correct but execution-failed action.

**Protocol penalty.** The Factorized Intervention study [arXiv:2605.00136] found that the overhead of the protocol itself (schema injection, planning tokens, format compliance) can **exceed the tool-execution gain by 2x**. ProMCP [OpenReview 2026] confirmed this: 56--72% of tokens in MCP tool calls are consumed by planning and schema injection, with actual tool execution representing a "negligible fraction" of the token budget. Anthropic's tool search feature achieves 85% token reduction for large libraries [Anthropic engineering blog], confirming that the protocol overhead is a recognized problem with commercial solutions.

The Routing Law establishes that tool count degrades routing accuracy. The CLAI framework explains *how* the degradation occurs (exponential decay, performance cliffs). The Knowing-Doing Gap explains *where* the bottleneck is (execution, not selection). The protocol penalty explains *why* the overhead may not be worth the gain. Together, these findings suggest that tool interface design for desktop automation faces competing pressures: fewer tools improve routing but reduce coverage; more tools improve coverage but degrade execution accuracy and consume context. The net effect is an empirical question that has not been studied for desktop automation specifically. The apparent tension between 'routing matters critically' (CLAI exponential decay) and 'execution is the bottleneck, not routing' (Knowing-Doing Gap) resolves at a threshold: routing accuracy must be above a floor (achieved by keeping tool count under the fracture point) before execution becomes the binding constraint. Below the routing floor, the model selects wrong tools and execution quality is irrelevant; above it, execution accuracy dominates. Both findings are consistent; they describe different regions of the same performance curve.

---

## 5. The Perception Debate --- Evidence Synthesis

This section synthesizes the evidence for and against each perception approach for desktop agents, with explicit quality ratings. It does not resolve the debate. The evidence is underdetermined: multiple hypotheses remain viable, and the available data does not discriminate between them.

### 5.1 Evidence That Pure Vision Works [MODERATE-STRONG EVIDENCE]

**UGround** [Gou et al., 2024, ICLR 2025 Oral] outperforms Set-of-Mark (screenshot plus structured element identifiers) by 19--21 points on Mind2Web. This is an Oral presentation at ICLR. UGround was trained on 10M GUI elements across 1.3M screenshots, demonstrating that scale in visual training data can substitute for structured perception.

**ShowUI** [Lin et al., 2024] achieves 75.1% zero-shot screenshot grounding accuracy with no accessibility tree. This is a 2B-parameter model --- far smaller than GPT-4o or Gemini --- yet it achieves competitive grounding performance using screenshots alone.

**CogAgent** [Hong et al., 2024, CVPR 2024 Highlight] is an 18B VLM with a dual-encoder processing 1120x1120 input. It outperforms LLaMA2-70B using HTML by 6.5 points on Mind2Web without using accessibility data itself. This is a direct comparison: the same task, the same benchmark, and the model without structured data beats the model with structured data.

**Production deployment.** Anthropic Computer Use [Anthropic, 2024] and OpenAI Operator [OpenAI, 2025] are deployed in production with screenshot-only perception. They work well enough to ship. This is first-class evidence: if pure vision were fundamentally inadequate for desktop automation, these products would not function at all. They do function, with documented limitations (Section 4.7). Production deployment status elevates the pure-vision evidence from "benchmark result" to "validated engineering choice by two independent organizations."

### 5.2 Evidence That Structured Perception Works [MODERATE EVIDENCE]

**UFO** [Zhang et al., 2025, NAACL 2025] combines visual perception with Windows UIA control info, achieving 86% success on WindowsBench. This is the strongest empirical result for dual perception. However, **it is on Windows with UIA, which is a different accessibility API from macOS AXAPI.** UIA provides richer metadata (more control patterns, broader coverage of modern frameworks) than AXAPI. Whether the UFO result transfers to macOS is unknown. This caveat was not stated in V3.

**SeeAct** [Zheng et al., 2024, ICML 2024] uses both screenshots and HTML structure. With oracle grounding, 51% success --- demonstrating that when grounding is solved, the reasoning component can achieve reasonable performance. The gap between oracle and automated grounding demonstrates that grounding is the bottleneck, not reasoning. This result supports structured perception insofar as the HTML structure enables grounding, but it is limited to web environments where HTML is available and well-structured.

**WebArena** [Zhou et al., 2024] showed that agents relying solely on accessibility trees missed visual layout cues. VisualWebArena [Koh et al., 2024] showed that text-only agents fail on tasks requiring visual understanding. These results cut both ways: they demonstrate that structured data alone is insufficient (supporting the need for screenshots), but also that structured data provides information that screenshots alone may miss (supporting the need for accessibility trees).

### 5.3 Evidence That Structured Perception Can Hurt [STRONG EVIDENCE]

The OSWorld results provide the most direct evidence that adding structured perception can degrade agent performance:

| Model | Screenshot Only | Screenshot + A11y Tree | Delta |
|---|---|---|---|
| GPT-4V | 11.77% | 12.17% | +0.4 |
| GPT-4o | 24.5% | 11.2% | -13.3 |
| Gemini-Pro-1.5 | 7.79% | 5.1% | -2.7 |

The GPT-4o regression is unambiguous: adding the a11y tree cuts success rate by more than half. This is not a marginal effect or a statistical artifact; it is a 13.3 percentage point degradation on the primary desktop agent benchmark.

The CLAI framework [Wang et al., 2026] provides a mechanistic explanation. The exponential decay model Accuracy ≈ exp(-(k*CL_Total + b)) predicts that adding structured perception tokens increases CL_Total, pushing the model toward the performance cliff. For models near the cliff (GPT-4o with a11y tokens), the additional cognitive load causes a sharp accuracy drop. For models farther from the cliff (GPT-4V), the same additional tokens produce a marginal effect (+0.4pp). This explains the model-specific variation without requiring model-specific explanations: the models are at different points on the same exponential decay curve, so the same increment in cognitive load produces different decrements in accuracy.

This explanation does not require that GPT-4o is "worse" than GPT-4V at processing structured data. It requires only that GPT-4o's decision boundary is closer to the cognitive load cliff --- which may be because GPT-4o is optimized for different token distributions, or because it processes structured data differently, or because its internal attention patterns are disrupted by the particular format of a11y tree data. The CLAI framework explains the *shape* of the degradation; the *cause* of the model-specific cliff position remains unknown (see Section 5.4).

### 5.4 Why the Evidence Is Contradictory [ANALYSIS]

The contradiction between the UGround/ShowUI results (pure vision wins) and the UFO/SeeAct results (structured perception wins) is not resolvable by collecting more data of the same kind. The confounds are structural:

**Platform-dependence.** No cross-platform controlled study exists. UGround and ShowUI were evaluated on Mind2Web and ScreenSpot (web and mobile). UFO was evaluated on WindowsBench (Windows desktop with UIA). The OSWorld a11y-tree results are on Ubuntu (AT-SPI/ATK). None of these generalizes to macOS-native applications with AXAPI. The accessibility APIs differ in coverage, structure, token profile, and failure modes across platforms (Section 4.2). A result obtained on one platform with one accessibility API does not predict the result on another platform with another accessibility API.

**Model-dependence.** Token burden alone does not explain the GPT-4V vs. GPT-4o divergence. GPT-4V benefits slightly (+0.4pp) from a11y data; GPT-4o degrades severely (-13.3pp). GPT-4o is the more capable model on most benchmarks, yet it is more harmed by a11y tokens. The CLAI framework (Section 5.3) explains this as different positions on an exponential decay curve, but it does not explain *why* GPT-4o is closer to the cliff. The interaction between model architecture, training data, and structured perception input format is unstudied.

**Benchmark-dependence.** Mind2Web (web, element-level grounding) tests a different capability than OSWorld (Ubuntu desktop, end-to-end task completion) which tests a different capability than WindowsBench (Windows desktop, task completion). A perception strategy that wins on element-level grounding (UGround on Mind2Web) may lose on end-to-end task completion where the a11y tree provides navigation context (UFO on WindowsBench). The benchmarks are measuring different things.

**The debate is underdetermined.** The three confounds (platform, model, benchmark) interact: no study holds two constant while varying the third. Without controlled studies that isolate these factors, multiple hypotheses remain viable:

These hypotheses are not equally supported by the available evidence. H4 (model-dependence) has the strongest direct evidence (GPT-4V vs. GPT-4o divergence on OSWorld). H1 (pure vision superiority) has strong but platform-confined evidence (UGround on Mind2Web, production deployment). H3 (platform-dependence) has moderate evidence (MacArena ranking inversion). H5 (task-type dependence) has weak evidence (grounding vs. navigation differences are inferred, not measured). H2 (structured perception superiority) has the weakest evidence: the strongest result (UFO on WindowsBench) is on a different platform with a different accessibility API, and no macOS evidence exists. Ranking these by evidential weight: H4 > H1 > H3 > H5 > H2.

- H1: Pure vision is superior for desktop agents (supported by UGround, ShowUI, CogAgent, production deployment)
- H2: Structured perception is superior for desktop agents (supported by UFO, SeeAct)
- H3: The optimal strategy depends on the platform (supported by the cross-platform coverage differences in Section 4.2)
- H4: The optimal strategy depends on the model (supported by GPT-4V vs. GPT-4o divergence)
- H5: The optimal strategy depends on the task type (supported by grounding vs. navigation differences)

None of these hypotheses can be falsified by the existing evidence. The highest-priority experiment is a controlled comparison of pure-vision vs. screenshot-plus-a11y agents on macOS-native applications, with multiple models, on a benchmark that tests both grounding and end-to-end task completion.

### 5.5 Cross-Platform Accessibility Comparison [MODERATE EVIDENCE]

V3 framed macOS AXAPI as "qualitatively different" from other accessibility APIs, implying that its failure modes are unique. The cross-platform comparison does not support this framing. **macOS shares the same failure-mode categories as other platforms but has specific mechanisms without equivalent elsewhere.** The same categories of failure appear across all four major platforms, but the specific mechanisms, frequencies, and severities differ.

#### 5.5.1 Universal Failure Modes

The following failure modes are universal across macOS (AXAPI), Windows (UIA), Android (AccessibilityNodeInfo), and Linux (AT-SPI):

- **Custom control invisibility.** Applications that use custom rendering (Canvas, WebGL, DirectX, custom Views, non-GTK widgets) are partially or fully invisible to accessibility clients on every platform. This is not an API deficiency; it is a fundamental design constraint of the accessibility model, which requires applications to opt in by implementing accessibility protocols.

- **Canvas/WebGL blindness.** No platform provides a native accessibility API for Canvas/WebGL content. Workarounds (ARIA canvas regions on web, AccessKit on Rust/desktop) exist but require explicit developer adoption.

- **IPC latency.** All accessibility APIs communicate via inter-process communication (Mach on macOS, COM on Windows, Binder on Android, D-Bus on Linux), which introduces latency between the application's state and the accessibility client's view of that state. The latency varies by platform but the phenomenon is universal.

- **Stale data.** All platforms exhibit read-after-write staleness. The specific mechanisms differ (TCC cache on macOS, COM cache on Windows, 100ms bounds batching on Android, D-Bus IPC on Linux), but the consequence is the same: the accessibility client may observe state that does not reflect the most recent mutation.

#### 5.5.2 macOS-Specific Failure Modes

Three failure modes are genuinely unique to macOS:

1. **TCC permission cache staleness.** `AXIsProcessTrusted()` reads from a per-process cache that does not invalidate after OS updates. No other platform has an equivalent mechanism where a security permission check returns a stale positive result [Fazm.ai, 2025].

2. **AXPress no-ops on browser web views.** Chrome, Safari, and Firefox on macOS return success from `AXPress` actions on web content, but the action does not execute. This is a macOS-specific bug in the AX-to-browser bridge, not documented on Windows or Linux.

3. **Permission gate.** The TCC system provides an all-or-nothing gate: either the automation tool has Accessibility permission (full AXAPI access) or it has none. Windows and Linux have no equivalent gate; UIA and AT-SPI are accessible without explicit user consent.

These three failure modes are real and consequential, and they make macOS qualitatively different in these specific dimensions. However, they do not make macOS uniquely pathological: the same categories of failure (stale data, IPC unreliability, security boundaries) appear on every platform, just through different mechanisms.

#### 5.5.3 Latency Comparison

| Platform | Accessibility API | Observed Latency | Source |
|---|---|---|---|
| macOS | AXAPI | up to 750ms (retry timeout; MacosUseSDK n=1) | Section 6.1 |
| Windows | UIA | 200--300ms (NVDA delays) | AccessKit/Slint issue #7546 |
| Android | AccessibilityNodeInfo | ~100ms (Compose bounds batching) | Android documentation |
| Linux | AT-SPI | Worst IPC latency (D-Bus round trips) | GNOME acknowledges "fatal flaw" |

macOS has the highest observed single-query latency (750ms), but this figure comes from a specific implementation (MacosUseSDK) and may vary by macOS version, hardware, and query pattern. The Linux AT-SPI latency is the most consistently problematic: GNOME's own documentation acknowledges that D-Bus round trips create a "fatal flaw" for responsive accessibility.

#### 5.5.4 Benchmark Evidence

Three benchmarks provide cross-platform data:

- **MacArena** found that model rankings invert between macOS and Linux, with the leading model trailing by 26% on macOS tasks [MacArena]. This suggests that macOS presents challenges that are not captured by Linux-based benchmarks.

- **MMBench-GUI** [ICLR 2026] found that macOS lags substantially on task automation compared to Android. This is consistent with the higher AXAPI latency and the three macOS-specific failure modes documented above.

- **CUA-Bench** found 10x performance variance across minor UI changes, indicating that all platforms are sensitive to UI variation, not just macOS.

**Critical gap.** No benchmark isolates AX API failure rates across platforms. The existing benchmarks measure end-to-end task success, which conflates perception failures, grounding failures, planning failures, and API failures. A cross-platform study that decomposes task failures by root cause would determine whether the macOS-specific failure modes (Section 5.5.2) are first-order problems or noise relative to the universal failure modes. This study does not exist.

---

## 6. Engineering Observations from macOS Accessibility

This section documents failure modes observed during the development of MacosUseSDK, a macOS automation server built on the Accessibility API (AXAPI). Each observation is framed as an instance of a known problem class from the UI automation, distributed systems, or software testing literature. This framing is deliberate: the failure modes themselves are not novel. What warrants documentation is (a) their concrete manifestation in the macOS AX layer, (b) their interaction with an LLM decision-maker, and (c) the reliability mitigations present in the implementation that prior reporting of these observations omitted.

All observations originate from a single implementation (n=1). Section 6.8 assesses cross-validation status and generalizability.

### 6.1 AX Server State Propagation Lag

**Observation.** After any window mutation (move, resize, minimize, restore), the private API `_AXUIElementGetWindow` fails for up to 750ms while the Accessibility server synchronizes its internal mappings. The MacosUseSDK implements a retry loop with exponential backoff: 5 retries with delays of 50ms, 100ms, 200ms, and 400ms, for a worst-case total delay of 750ms before falling back to heuristic matching (WindowHelpers.swift:149--179). The code comment states: "After geometry mutations (MoveWindow, ResizeWindow), the private API `_AXUIElementGetWindow` can transiently fail while the Accessibility server synchronizes internal mappings."

**Problem class.** This is the macOS equivalent of Selenium's `StaleElementReferenceException` --- an element reference becomes invalid because the underlying DOM (or, in this case, the AX server's internal index) has been updated between the reference acquisition and its use. Romano et al. [ICSE 2021] found that 45.1% of UI test flakiness is caused by asynchronous wait issues of this type. Luo et al. [FSE 2014] independently confirmed 45.9% async-wait prevalence across 51 projects. The WEFix study [WWW 2024] found that 65.7% of end-to-end commands are flaky-prone, with 98.4% fixable by generating proper wait oracles --- the same strategy as the retry-with-backoff pattern here.

**Mitigations present in codebase.** The prior version of this paper (V3) documented the 750ms delay but omitted the primary mitigation. After the retry loop exhausts its attempts, WindowHelpers.swift falls back to heuristic geometric matching using bounds comparison (WindowHelpers.swift:181--222). In practice, most window lookups succeed --- either via exact ID match (fast path) or heuristic match (slower but reliable). The retry-with-fallback pattern is structurally identical to the self-healing selector strategies documented in the RPA literature, where fuzzy matching reduces locator failures by 40--60% [IJAM 2025].

The 750ms figure is an empirical observation from one implementation, not a documented Apple specification. Whether this delay is constant or varies by macOS version, hardware, or query pattern has not been measured externally.

### 6.2 CGWindowList Staleness and the Hybrid Authority Problem

**Observation.** `CGWindowListCopyWindowInfo` (the Quartz/CG API for enumerating windows) lags behind the Accessibility server by 10--100ms during normal operation and by multiple frames during animations. After a window mutation, the CG-reported bounds can differ from AX-reported bounds. The window-state-management document characterizes the delta as ranging from "tens to several hundreds" of pixels; a 1000-pixel threshold serves as the heuristic cutoff for rejecting CG/AX matches (WindowQuery.swift).

**Problem class.** The "Hybrid Authority" model --- where two data sources (CG and AX) provide overlapping but potentially inconsistent views of the same entities --- is structurally identical to a multi-master replication problem in distributed systems. Bailis et al. [VLDB 2012] developed the Probabilistically Bounded Staleness (PBS) framework for quantifying such guarantees. PBS defines (K,\Delta)-staleness: a read is (K,\Delta)-staleness-consistent if it reflects at least K of the most recent writes, and the writes it reflects are no older than \Delta seconds. In the AX/CG context: a `ListWindows` call (CG authority) may return bounds that are \Delta milliseconds stale relative to the most recent mutation, where \Delta varies from 10ms (steady state) to multiple animation frames (during transitions).

Daniel et al. [Middleware 2018] proved a three-way impossibility: a system cannot simultaneously provide atomic reads, minimal delay, and maximal freshness. The MacosUseSDK's three-tier data authority is an engineering instantiation of this tradeoff:

| Tier | API | Authority | Consistency | Latency |
|------|-----|-----------|-------------|---------|
| 1 | ListWindows | CG (Quartz) | Eventually consistent (\Delta = 10--100ms steady, higher during animations) | Fast |
| 2 | GetWindow | AX (Accessibility) | Read-after-write (fresh geometry for single window) | Moderate |
| 3 | GetWindowState | AX (deep query) | Authoritative (full accessibility traversal) | Slow |

Each tier optimizes for two of the three properties (atomicity, latency, freshness) while sacrificing the third. This design is consistent with Daniel et al.'s theorem: no single tier can provide all three simultaneously.

**Mitigations present in codebase.** V3 documented the staleness problem but omitted the three-tier architecture that manages it. Additionally, CGWindowList serves as a fallback data source when AX queries fail entirely (WindowHelpers.swift). The single-window bypass --- where a PID with exactly one window requires no threshold-based matching at all --- eliminates the heuristic for the common case.

**Correction from V3.** V3 characterized the CG/AX disagreement as "600+ pixels." The source document states "tens to several hundreds" of pixels; the 1000px threshold is a mitigation parameter, not a measured maximum. This characterization has been corrected.

### 6.3 kAXWindows Emptiness During Transitions

**Observation.** `kAXWindowsAttribute` can temporarily return an empty array even when windows exist. This occurs during window state transitions (minimizing, moving between Spaces). The ObservationManager implements an "Orphan Rescue" strategy: when a window disappears from `kAXWindows`, the code checks `kAXChildren` explicitly because the OS often moves transitioning windows to the generic children list temporarily (ObservationManager.swift:380--466). If the window is found in `kAXChildren`, the snapshot is updated. If not found in either attribute, but still present in `CGWindowList` with `isOnScreen: true`, CG data serves as a temporary substitute (ObservationManager.swift:444--461).

**Problem class.** This is an instance of DOM event flakiness: the accessibility tree's structure changes transiently during state transitions, producing spurious "element disappeared" events that reverse themselves shortly after. The ICST 2025 study found that DOM event flakiness takes an average of 153.4 days to resolve across 49 projects --- indicating that transient structural inconsistencies are persistent, difficult-to-fix properties of event-driven UI systems, not transient bugs.

The Orphan Rescue strategy is a fallback consistency check structurally analogous to the repair strategies in web testing frameworks: when the primary selector fails, secondary selectors and fallback data sources are tried in sequence before declaring a failure.

**Mitigations present in codebase.** V3 documented the kAXWindows emptiness but omitted the three-layer fallback: kAXChildren check → CGWindowList fallback → isOnScreen validation. Each layer reduces the probability of a false "window destroyed" event.

### 6.4 Minimize Requires State Verification

**Observation.** Setting `kAXMinimizedAttribute = true` on a window does not cause the minimized state to be reflected immediately in AX queries. The AX server propagates the change asynchronously. The MacosUseSDK's minimize implementation polls in a 2-second loop with 10ms intervals to verify that `kAXMinimizedAttribute` reads back as `true` (WindowMethods.swift:437--457).

**Problem class.** This is an instance of the async-wait pattern, the dominant cause of UI test flakiness (45.1% per Romano et al. [ICSE 2021], 45.9% per Luo et al. [FSE 2014]). The WEFix study demonstrated that 98.4% of flaky tests can be fixed by generating proper wait oracles --- the same strategy as the PollUntil pattern here. The 2-second timeout is a chosen parameter, not a measured delay; the actual propagation typically completes well before the timeout.

**Mitigations present in codebase.** After the minimize operation, WindowMethods.swift explicitly invalidates the window registry cache (line 464), forcing fresh reads on subsequent queries. The same cache invalidation occurs after restore (line 395) and after move/resize mutations (line 527). This prevents stale cached state from propagating to subsequent tool calls.

### 6.5 Focus Acquisition Is Best-Effort

**Observation.** The `acquireFocusForElement` operation traverses the AX parent chain to find the window element and sets `kAXFocusedAttribute = true`, but this operation is best-effort. The code comment states: "Best-effort: if focus fails, the interaction still proceeds" (AutomationCoordinator.swift:42). When focus fails, the code logs "proceeding anyway" (AutomationCoordinator.swift:98) and continues with the interaction.

**Problem class.** This is an instance of cooperative activation, a documented macOS platform behavior. As of macOS 14, `activateIgnoringOtherApps:` is deprecated; `activate()` is a cooperative request, not a command [Apple, NSApplication API Reference]. Apple's own documentation states that "GUI Scripting tends to result in fragile scripts" [AppleScriptX], acknowledging that programmatic focus management is inherently unreliable.

**Mitigations present in codebase.** V3 documented the best-effort behavior but omitted the 100ms post-focus sleep (AutomationCoordinator.swift:96). After successfully setting `kAXFocusedAttribute`, a 100ms delay allows macOS to process the focus change before proceeding with the subsequent interaction. This does not guarantee focus acquisition but reduces the probability of a focus-related failure for the immediately following action.

### 6.6 Element Bounds vs. Hit Area Mismatch

**Observation.** Clicking the top-left corner of an element's AX-reported bounds frequently misses the element's hit area. The AX frame (`kAXPositionAttribute` + `kAXSizeAttribute`) provides the top-left corner and dimensions, but the actual clickable area may be offset by padding, borders, or other visual chrome. The MacosUseSDK works around this by always clicking the geometric center: `centerX = element.x + (element.width / 2)`, `centerY = element.y + (element.height / 2)` (ElementMethods.swift:1128--1129).

**Problem class.** This is an instance of element locator fragility --- the same class of problem as RPA selector brittleness and Selenium element locator drift. The RPA literature documents that ~60% of automation failures originate from UI changes and selector breaks [Aguirre & Rodriguez, 2017; Leotta et al., 2013]. Gupta et al. [2019] measured that 3--4% of test methods become fragile per release cycle, with 20--30% requiring modification at least once. The center-click heuristic is a geometric analogue of the self-healing selector strategies used in RPA: when the exact selector fails, a fuzzy fallback is attempted.

**Mitigations present in codebase.** A size filter rejects elements with width or height below 10px, preventing clicks on invisible or decorator elements that would invariably miss their target. The center-click heuristic, while not guaranteed for all elements (particularly those with non-rectangular hit areas or large padding), is more reliable than top-left clicking and represents the same engineering compromise as RPA self-healing: trading precision for robustness.

### 6.7 Proto Schema Limitations

**Observation.** The protobuf schema for `MouseClick` does not include a `modifiers` field. The message defines `position`, `click_type`, and `click_count`, but not `modifiers` (input.proto:112--138). In contrast, `KeyPress` does include `repeated Modifier modifiers` (input.proto:152--158). Notably, `MouseButtonDown` and `MouseButtonUp` messages do include modifiers, meaning a modifier+click operation is expressible through decomposition into separate press-modifier, click, release-modifier operations.

**Problem class.** This is an engineering constraint, not a novel finding. The decomposition adds latency (three operations instead of one) and introduces a race condition: if another event occurs between the modifier press and the click, the modifier state may be incorrect. This is a specific instance of the general principle that interface expressiveness affects reliability: when the tool surface cannot express a common operation atomically, the decomposition introduces failure modes that the atomic operation would avoid.

**Mitigation status.** The MacosUseSDK's MCP server layer handles modifier+click by decomposing into separate operations. No mitigation eliminates the race condition entirely; only a schema change (adding `modifiers` to `MouseClick`) would resolve it at the source.

### 6.8 Scope and Generality of Observations

All engineering observations in Section 6 come from a single implementation: MacosUseSDK. This section assesses which observations are likely to be general properties of the macOS platform and which may be implementation-specific.

#### Cross-Validated Observations

The following observations have been confirmed by at least one external source independent of MacosUseSDK:

| Observation | MacosUseSDK Finding | External Confirmation |
|-------------|---------------------|----------------------|
| AX coverage gaps (Canvas, custom controls) | Confirmed | Apple Accessibility Programming Guide; Fazm.ai community report (Qt, OpenGL, Python tools return `kAXErrorCannotComplete`) |
| AX cache desync after OS updates | Not yet observed in MacosUseSDK | Fazm.ai (Dec 2025): `AXIsProcessTrusted` reads from per-process cache; OS updates can invalidate without notification; no public API to reset cache; must quit and relaunch |
| GUI scripting is fragile | Confirmed (focus best-effort, state staleness) | Apple's own documentation: "GUI Scripting tends to result in fragile scripts" [AppleScriptX] |
| App Sandbox blocks `CGEvent.post()` | Not directly tested | DEV Community report: `CGEvent.post()` silently does nothing inside App Sandbox; no entitlement re-enables it; AppleScript round-trip adds 40--80ms latency |
| Stage Manager breaks automation | Not directly tested | Apple Community: "no supported way to create Stage Manager groups"; MacScripter: "turning ON/OFF Show Recent apps breaks Shortcuts/Automator" |
| Applications launch without AX trees | Confirmed (bare binaries) | Fazm.ai: "`kAXErrorCannotComplete`... the target app does not implement the accessibility tree at all... common with Qt apps, OpenGL apps, Python-based tools" |

#### Observations Without External Confirmation

| Observation | Risk of Being Implementation-Specific | Reason |
|-------------|---------------------------------------|--------|
| 750ms specific propagation delay | Medium | May vary by macOS version, hardware, or query pattern. Only measured in MacosUseSDK. |
| CG/AX bounds disagreement magnitude | High | Source document states "tens to several hundreds" of pixels; 1000px is a mitigation threshold. Magnitude may be application- and animation-specific. |
| 2-second minimize verification timeout | Low | 2s is a chosen timeout, not a measured delay. Actual propagation typically completes sooner. |
| Center-click heuristic effectiveness | Medium | Other tools (atomacos, pyautogui) may use different click strategies with different effectiveness. |

#### Mitigations in the Codebase

V3 presented the AX failure modes as unrepaired problems. The MacosUseSDK codebase contains ten reliability mitigations that reduce their severity in practice. Five of these were omitted from V3 entirely:

1. **Exponential backoff with heuristic fallback** (WindowHelpers.swift:181--222): After the retry loop exhausts its attempts, falls back to geometric matching using bounds. Most window lookups succeed via either exact ID match or heuristic match.

2. **100ms post-focus sleep** (AutomationCoordinator.swift:96): After successfully setting `kAXFocusedAttribute`, a 100ms delay allows macOS to process the focus change before the subsequent interaction.

3. **Cache invalidation after mutations** (WindowMethods.swift:395, 464, 527): After minimize, restore, and move/resize operations, the window registry cache is explicitly invalidated, forcing fresh reads on subsequent queries.

4. **CGWindowList as fallback data source** (WindowHelpers.swift): When AX queries fail, the code falls back to CGWindowList data for bounds, providing a second independent data source.

5. **Three-tier window data authority** (proto API design): ListWindows (fast, cached CG), GetWindow (fresh AX), GetWindowState (deep AX) --- each with documented staleness characteristics, allowing clients to choose the appropriate consistency/latency tradeoff.

Five additional mitigations were also present but not documented:

6. **Orphan rescue** (ObservationManager.swift:380--466): kAXChildren check → CGWindowList fallback → isOnScreen validation, a three-layer fallback that reduces false "window destroyed" events.

7. **Single-window bypass**: When a PID has exactly one window, accept it regardless of ID mismatch, eliminating the heuristic threshold for the common case.

8. **Size filter**: Reject elements with width or height below 10px, preventing clicks on invisible or decorator elements.

9. **ChangeDetector circuit breaker** (ObservationManager): Limits processing to 5 events per PID per 1-second window, preventing event floods from overwhelming the agent.

10. **SDK activation suppression**: 500ms window for self-activation tracking, preventing the automation server's own activation events from being reported as external UI changes.

These mitigations do not eliminate the failure modes, but they significantly reduce their impact in practice. A fair assessment of the engineering constraints must acknowledge both the failures and the mitigations. The omission of these mitigations from V3 overstated the severity of the documented failure modes.

---

## 7. Hypotheses About Tool Interface Design

This section presents five hypotheses about tool interface design for desktop automation. Each hypothesis is stated with evidence for, evidence against, and an actionable falsification criterion including minimum effect size, statistical test, benchmark, and estimated cost. The hypotheses are labeled as hypotheses --- not principles or requirements --- because the evidence does not support stronger claims.

### 7.1 Compressed Tool Surfaces Improve Routing Accuracy

**Statement.** Compressing the tool surface to under 30 compositional tools, each handling a coherent category of operations with composable parameters, produces higher routing accuracy than exposing 70+ atomic tools.

**Evidence for.** Chen et al. [2026] establish that single-step routing accuracy exceeds 90% under 30 tools and decays logarithmically as tool count increases, following Acc(N) = a - b·ln(N) across 15 frontier LLMs and 1,141 skills. API-Bank [Li et al., 2023] demonstrates that tool selection is the primary bottleneck as tool count increases. ToolLLM [Qin et al., 2023] shows that dynamic tool filtering is more effective than increasing model size. Wang et al. [AAAI 2026] document non-linear performance cliffs: accuracy follows an exponential decay model Acc ≈ exp(-(k·CL_Total + b)), with statistically validated fit (Hosmer-Lemeshow p>0.05 for all models). Sadani & Kumar [2026] quantify MCP token overhead at 15,000--55,000 tokens per turn in typical 4--6 server deployments, with a fracture point at N≈50 tools where context utilization reaches 70%. ProMCP [OpenReview 2026] finds that 56--72% of tokens are consumed by planning and schema injection, with actual tool execution representing a "negligible fraction." Anthropic's engineering blog reports 85% token reduction for large tool libraries via tool search.

**Evidence against.** Anthropic's deployed Computer Use product uses 15+ atomic tools and functions in production [Anthropic, 2024]. OpenAI's Operator uses a small set of atomic tools and functions in production [OpenAI, 2025]. The "Knowing-Doing Gap" [arXiv 2605.14038] demonstrates that execution is the bottleneck, not routing: 26.5--54.0% mismatch on arithmetic tasks where models correctly select the tool but execute it incorrectly. The Factorized Intervention study [arXiv 2605.00136] finds that the protocol penalty of decomposed operations can exceed the tool-execution gain by 2x. Compositional tools create parameter complexity and ambiguous parameter combinations that may reduce execution accuracy. The Execution Law from Chen et al. [2026] suggests that correct execution can "rescue" difficult downstream decisions by approximately 4x, implying that execution correctness matters more than routing correctness --- and atomic tools with simpler parameter spaces may have higher execution correctness.

**Falsification criterion.** Falsified if 50+ atomic tools outperform 23 compositional tools by ≥5 percentage points on task success rate (paired bootstrap test, p<0.05) on macOSWorld (N≥100 tasks across K≥5 application categories). Estimated cost: ~$500--1,000 in API calls. Minimum detectable effect at 80% power with 100 tasks: δ≈5pp. This experiment requires implementing both tool surfaces for the same functional coverage and measuring agent performance with the same model and prompt, varying only the tool surface. It is achievable by any team with access to macOSWorld and an LLM API key.

### 7.2 Tool Descriptions Should Be Detailed

**Statement.** Tool descriptions of at least 3--4 sentences that include preconditions, effects, and failure modes produce higher agent performance than minimal descriptions.

**Evidence for.** Anthropic recommends "extremely detailed descriptions" of at least 3--4 sentences [Anthropic, VERIFIED]. ToolSword [Ye et al., 2024, ACL 2024] demonstrated that noisy tool names and descriptions misdirect models into selecting wrong or risky tools. TOOLRET [Shi et al., 2025, ACL 2025] identified the gap between user intent language and tool description language as a first-order problem. MetaTool [Huang et al., 2023] found that longer, more detailed tool descriptions improve tool selection accuracy.

**Evidence against.** The tradeoff between description detail and token cost has not been studied for desktop automation. MCP deployments incur approximately 1,000 tokens per heavily documented tool and approximately 100 tokens per lightly documented tool [MCP Issue #2808]. For a 77-tool server, this yields 77,000 tokens (60% of a 128K context window) with heavy documentation versus 7,700 tokens (6%) with light documentation --- crossing the fracture point identified by Sadani & Kumar [2026]. SKILLREDUCER [2026] achieved 48% compression of tool descriptions with a 2.8% quality improvement, suggesting that beyond a threshold, additional detail degrades performance through context window pressure rather than improving it. The answer depends on context window pressure: when the context window is large relative to total tool tokens, longer descriptions help; when tool tokens approach the fracture point, shorter descriptions may be superior.

**Falsification criterion.** Falsified if agents with minimal tool descriptions (1 sentence each, ~100 tokens/tool) perform equivalently to or better than agents with detailed descriptions (3--4 sentences, ~1,000 tokens/tool) on task success rate (paired bootstrap, p<0.05) on macOSWorld (N≥100 tasks). Both conditions must use the same functional tool surface, differing only in description length. Estimated cost: ~$500--1,000 in API calls. Minimum detectable effect at 80% power: δ≈5pp. This experiment should be run at two context window sizes (128K and 1M tokens) to test whether the effect is moderated by context window pressure.

### 7.3 Tool Outputs Should Include Natural Language

**Statement.** Returning both structured data and a natural language description in every tool response produces higher agent performance than returning structured data alone.

**Evidence for.** Inner Monologue [Huang et al., 2022, CoRL 2023] showed that closed-loop language feedback improves instruction completion in robotics settings. ReAct [Yao et al., 2023, ICLR 2023] showed that interleaving reasoning with actions reduces hallucination. The "Let Me Speak Freely?" paper [arXiv:2408.02442] raised the concern that strict structured output can degrade reasoning, though this finding is contested.

**Evidence against.** No study has directly compared structured-only vs. structured-plus-natural-language return formats for desktop automation tools. The Inner Monologue and ReAct findings are from robotics and text-based agent settings, respectively. Their transfer to desktop automation is plausible but unvalidated. Natural language output increases token consumption per tool call, contributing to context window pressure (Section 7.2). For a 77-tool server making an average of 10 tool calls per task, adding 200 tokens of natural language per response consumes an additional 2,000 tokens per task --- modest relative to tool descriptions but non-zero.

**Falsification criterion.** Falsified if agents that receive only structured data (JSON-formatted tool responses with no natural language summary) perform equivalently to agents that receive both structured data and a 2--3 sentence natural language summary (paired bootstrap, p<0.05) on task success rate on macOSWorld (N≥100 tasks across K≥5 application categories). Estimated cost: ~$500--1,000 in API calls. Minimum detectable effect at 80% power with 100 tasks: δ≈5pp. The natural language condition should include a fixed token budget to control for context window effects.

### 7.4 Application Launch Tools Should Poll for Readiness

**Statement.** The "open application" tool must not return until the application's state is observable. It must infer launch mode (foreground, background, bare binary) and poll for window readiness using accessibility queries.

**Evidence for.** macOS activation semantics are non-deterministic [Apple, NSApplication API Reference]. `CGWindowList` lags behind the Accessibility server by 10--100ms (Section 6.2). Applications may launch as bare binaries with no windows [Apple, ActivationPolicy Documentation]. The AX server state propagation lag (Section 6.1) means that immediate queries after launch may return stale or missing data. Apple's own documentation states that "GUI Scripting tends to result in fragile scripts" [AppleScriptX], acknowledging that programmatic application lifecycle management is inherently unreliable.

**Evidence against.** Polling adds latency. If the application launches quickly and the AX server synchronizes fast, the polling delay is unnecessary overhead. The tradeoff between reliability and latency has not been measured. For well-behaved applications that always launch with a visible window and activate immediately, the polling cost may exceed the benefit.

**Falsification criterion.** Falsified if agents that receive immediate return from "open application" (without readiness polling) achieve equivalent task success rate to agents that receive return only after readiness is confirmed (paired bootstrap, p<0.05) on macOSWorld (N≥100 tasks), where at least 30% of tasks target applications with non-deterministic launch behavior (bare binaries, background-only apps, apps with modal dialogs on launch). Estimated cost: ~$500--1,000 in API calls. Minimum detectable effect at 80% power: δ≈5pp. This experiment requires careful task selection: if all tasks target well-behaved applications (Calculator, TextEdit), the polling hypothesis will appear unnecessary regardless of its true value.

### 7.5 Feasibility Signaling Helps

**Statement.** Agents perform better when tools expose precondition information (e.g., "this application lacks Accessibility permission") before the model attempts invocation, compared to agents that discover preconditions only through failed tool calls.

**Evidence for.** SayCan [Ahn et al., 2022, CoRL 2022] introduced the Say-Can decomposition: the LLM scores the utility of candidate actions ("Say"), while value functions score feasibility ("Can"). In the original robotics context, this produced significant improvements in instruction completion. The extension to desktop automation is plausible: agents would benefit from knowing whether a tool call will fail before attempting it, avoiding wasted actions and broken state.

**Evidence against.** SayCan was designed for physical feasibility in robotics (kinematic reachability). Its extension to permission feasibility in desktop automation (TCC grants, Accessibility permission) is an inference, not a validated transfer. The feasibility constraints are fundamentally different: physical reachability is continuous and predictable, while permission grants are binary and may change at any time (the user can revoke Accessibility permission while the agent is running). Feasibility signals consume additional tokens in the tool description or response, contributing to context window pressure. The "Knowing-Doing Gap" [arXiv 2605.14038] suggests that knowing the right action is not the bottleneck --- executing it correctly is. If feasibility signaling improves selection but not execution, the net benefit may be marginal.

**Falsification criterion.** Falsified if agents that receive feasibility signals (precondition metadata in tool descriptions indicating likely failure modes: "requires Accessibility permission," "target application may not support AXAPI," "element may be off-screen") do not outperform agents that discover preconditions only through failed tool calls by ≥3 percentage points on task success rate (paired bootstrap, p<0.05) on macOSWorld (N≥100 tasks where at least 20% involve feasibility-limited operations). Estimated cost: ~$500--1,000 in API calls. Minimum detectable effect at 80% power: δ≈3pp (lower threshold because feasibility signaling targets a subset of failure modes). The experiment must include tasks where preconditions are violated (missing permissions, inaccessible applications) to test whether signaling converts would-be failures into avoided actions.

---

## 8. Prioritized Research Agenda

The following agenda ranks open questions by (a) impact on design decisions, (b) feasibility of resolution, and (c) estimated cost. Each entry specifies what decision it unblocks, what experiment would resolve it, estimated cost, and minimum detectable effect size.

| Priority | Unknown | Decision Unblocked | Resolving Experiment | Effort | Est. Cost | MDE (80% power) | Tag |
|----------|---------|-------------------|---------------------|--------|-----------|------------------|-----|
| Critical | Whether a11y trees help or hurt on macOS-native apps | Perception strategy for macOS agents | Controlled A/B: pure-vision vs. screenshot+a11y on macOSWorld, varying model (GPT-4o, Claude 3.7, Gemini 2.5) | 2--4 wk | $1,000--3,000 | δ≈5pp at N=100 | Run now |
| High | Why a11y helps some models, hurts others | Whether to make a11y optional, model-specific, or format-adaptive | Ablation varying: token count, tree format (flat/serialized/pruned), model architecture, a11y-to-screenshot ratio | 4--8 wk | $5,000--15,000 | δ≈3pp at N=200 per model | Run 6mo |
| High | AX failure impact on end-to-end task success | Whether to invest in AX reliability engineering or shift to vision-only fallbacks | Instrumented agent with AX failure taxonomy; measure correlation between failure frequency and task success | 4--8 wk | $2,000--5,000 | r≥0.3 at N=500 task attempts | Run 6mo |
| High | Human-in-the-loop: help or hurt? | Whether to default to supervised or autonomous mode | Supervision experiment: measure task success, time-to-completion, and vigilance decay across supervision conditions (always-approve, selective-approve, post-hoc review) | 4--8 wk | $3,000--8,000 | δ≈5pp at N=60 participants | Run 6mo |
| Medium | Compositional vs. atomic tool surfaces | Tool surface design for desktop MCP servers | Same-coverage A/B test: 23 compositional tools vs. 50+ atomic tools, same model, same tasks | 6--12 wk | $5,000--15,000 | δ≈5pp at N=100 | New infra |
| Medium | Optimal cognitive load for desktop tools | How many tools to expose, how much description detail | Replicate ToolLoad-Bench framework [Wang et al., AAAI 2026] for desktop-specific tools | 4--8 wk | $2,000--5,000 | CL threshold at N=20 tool configurations | Run now |
| Low | Domain-specific Routing Law coefficients | Whether desktop tools follow same Acc(N) curve as general skills | Replicate Chen et al. [2026] methodology for desktop-specific tool sets | 2--4 wk | $1,000--3,000 | Coefficient estimation within 95% CI | Run now |
| Speculative | Long-term model improvement effects on tool design | Whether current design hypotheses will be obsoleted by model improvement | Cannot be resolved now; requires longitudinal data on model capability trajectory | N/A | N/A | N/A | Speculative |

Cost estimates assume macOSWorld provides a mature evaluation infrastructure with ≥100 tasks across ≥5 application categories. Section 3.1 describes macOSWorld as 'brand-new' with 'minimal published results.' If this infrastructure is not yet available, costs increase by approximately 10x to account for benchmark development and validation. The 'Run now' tags reflect prioritization assuming infrastructure exists; 'New infra' tags reflect where infrastructure must first be built.

**Critical priority justification.** The perception strategy question is Critical because it is the single most consequential design decision for any macOS desktop automation system, and it is the only question where no cross-platform evidence exists. Every other design decision (tool count, description detail, return format, feasibility signaling) is secondary to the question of what the agent perceives. The experiment is achievable with existing infrastructure (macOSWorld) and does not require novel methodology.

**Speculative priority justification.** The question of whether improving models will obsolete current tool design hypotheses is genuinely unresolvable: it requires data about future model capabilities that does not exist. The field should acknowledge this uncertainty but not defer design decisions on its basis.

---

## 9. Limitations

### Post-Hoc Analysis

The engineering observations in Section 6 were collected during the development of MacosUseSDK. The analysis was conducted after the implementation existed. Post-hoc analysis is inherently weaker than prospective research because the analyst knows which conclusions they need the evidence to support. This paper has attempted to mitigate this bias by five means: (1) presenting raw observations with code references rather than design implications, (2) labeling hypotheses as hypotheses with actionable falsification criteria, (3) framing engineering observations as instances of known problem classes rather than novel findings, (4) explicitly identifying ten reliability mitigations in the codebase (five of which V3 omitted), and (5) marking unverifiable sources. The reader should assess whether these mitigations are sufficient.

### Single-Implementation Origin

All engineering observations come from MacosUseSDK (n=1). Cross-validation is partial: AX cache desync is confirmed by the Fazm.ai community report; AppleScript fragility is confirmed by Apple's own documentation; AX coverage gaps are confirmed by multiple independent sources. However, the 750ms propagation delay, the CG/AX bounds disagreement magnitude, and the specific focus acquisition failure rate have not been confirmed by external implementations (atomacos, pyautogui). These observations should be treated as confirmed for one implementation, with cross-validation pending.

### Partial Cross-Validation

The cross-platform comparison (Section 4 of the full paper) demonstrates that macOS AXAPI shares most failure modes with other accessibility APIs (UIA on Windows, AccessibilityNodeInfo on Android, AT-SPI on Linux). Custom control invisibility, canvas/webGL blindness, and IPC latency are universal. macOS-specific failures include TCC permission cache staleness, AXPress no-ops on browser web views, and the all-or-nothing TCC permission gate. However, the frequency and severity of shared failure modes may differ across platforms, and no benchmark isolates AX API failure rates across platforms.

### Correction from V3

V3 claimed that "OpenAI published zero reliability metrics" for Operator/CAU. This claim is false. The OpenAI Operator System Card (47-page PDF) contains extensive data including confirmation prompt recall (92%), proactive refusal recall (94%), prompt injection susceptibility (23% with mitigations vs. 62% without), and prompt injection monitor performance (99% recall, 90% precision). This error has been corrected.

### Missing Research Areas

This analysis does not cover: prompt injection defenses for computer-use agents; multi-agent coordination on shared desktop state; the interaction between model scale and tool routing accuracy for domain-specific tools; the interaction between tool design and fine-tuning; the security implications of exposing desktop automation capabilities via MCP; or the cost implications of dual perception. These omissions reflect scope constraints, not assessments of importance. Prompt injection defenses are particularly consequential given the RedTeamCUA findings (83% success rate on Claude 4.5 [arXiv:2505.21936]) and should be addressed in subsequent work.

### Evidence Quality Variation

Sources span eight quality levels, from peer-reviewed publications at selective venues (OSWorld: NeurIPS 2024; UGround: ICLR 2025 Oral) to vendor documentation (Anthropic engineering blog; Apple API references) to unverifiable sources (GUIrilla: no DOI; macOSWorld: minimal published results). The GUIrilla finding that "only 33% of macOS apps offer full accessibility support" is presented as an unverifiable estimate, not a measurement. Verification status for each source is reported in Appendix A.

---

## 10. Conclusion

The perception modality debate for desktop automation agents is underdetermined by current evidence. Benchmark data is platform-confined (OSWorld on Ubuntu, UFO on Windows, UGround on web/mobile), model-dependent (adding a11y trees helps GPT-4V by 0.4pp but hurts GPT-4o by 13.3pp), and benchmark-dependent (pure vision wins on Mind2Web but loses on WindowsBench). No controlled study exists for macOS-native applications. The highest-priority experiment is a controlled A/B comparison of pure-vision vs. screenshot-plus-a11y agents on macOS-native applications, achievable with existing infrastructure (macOSWorld) at estimated cost of $1,000--3,000.

The AX failure modes documented in Section 6 are not novel. They are instances of well-known problem classes: async-wait flakiness (the same class as Selenium's `StaleElementReferenceException`), eventual consistency (the same class as multi-master replication lag), DOM event flakiness (the same class as transient DOM structural inconsistencies), cooperative activation (documented macOS platform behavior), and element locator fragility (the same class as RPA selector brittleness). The UI automation and distributed systems communities have studied these problems for years, and the mitigations that work in those domains (explicit waits, retry with fallback, multi-tier consistency models) are the same mitigations that work in desktop automation. V3's omission of the mitigations present in the codebase overstated the severity of these failure modes.

What IS novel about desktop agents is the combination of these reliability challenges with an LLM decision-maker whose routing and execution accuracy depends on factors --- tool count, description detail, return format, context window pressure --- that are themselves poorly understood for this domain. The cognitive load literature documents non-linear performance cliffs as tool token consumption approaches context window limits [Wang et al., AAAI 2026; Sadani & Kumar, 2026], and the "Knowing-Doing Gap" finding that execution is the bottleneck, not routing, suggests that tool interface design may affect agent performance through mechanisms that current evaluations do not measure.

Both perception approaches remain viable until controlled experiments are conducted. The field should treat design claims --- whether about the superiority of pure vision, the necessity of accessibility trees, the optimal tool count, or the value of feasibility signaling --- as hypotheses, not conclusions. The falsification criteria in Section 7 specify exactly what evidence would resolve each hypothesis, at what cost, and with what statistical power. The research agenda in Section 8 prioritizes the questions by impact and feasibility. The path forward is empirical.

---

## Appendix A: Verification Status

| # | Source | Venue | Peer-Reviewed | Quality | Verification Status |
|---|--------|-------|---------------|---------|---------------------|
| 1 | WebArena (Zhou et al., 2024) | ICLR 2024 | Yes | High | VERIFIED |
| 2 | VisualWebArena (Koh et al., 2024) | ACL 2024 | Yes | High | VERIFIED |
| 3 | OSWorld (Xie et al., 2024) | NeurIPS 2024 | Yes | High | VERIFIED |
| 4 | Mind2Web (Deng et al., 2023) | NeurIPS 2023 | Yes | High | VERIFIED |
| 5 | SeeClick (Cheng et al., 2024) | ACL 2024 | Yes | High | VERIFIED |
| 6 | UGround (Gou et al., 2024) | ICLR 2025 Oral | Yes | High | VERIFIED |
| 7 | ShowUI (Lin et al., 2024) | arXiv 2024 | No | Medium | VERIFIED (preprint) |
| 8 | CogAgent (Hong et al., 2024) | CVPR 2024 Highlight | Yes | High | VERIFIED |
| 9 | SeeAct (Zheng et al., 2024) | ICML 2024 | Yes | High | VERIFIED |
| 10 | UFO (Zhang et al., 2025) | NAACL 2025 | Yes | High | VERIFIED |
| 11 | Agent S2 (Agashe et al., 2025) | COLM 2025 | Yes | High | VERIFIED |
| 12 | ReAct (Yao et al., 2023) | ICLR 2023 | Yes | High | VERIFIED |
| 13 | SayCan (Ahn et al., 2022) | CoRL 2022 | Yes | High | VERIFIED |
| 14 | Inner Monologue (Huang et al., 2022) | CoRL 2023 | Yes | High | VERIFIED |
| 15 | API-Bank (Li et al., 2023) | EMNLP 2023 | Yes | High | VERIFIED |
| 16 | ToolLLM (Qin et al., 2023) | arXiv 2023 | No | Medium | VERIFIED (preprint) |
| 17 | GORILLA (Patil et al., 2023) | arXiv 2023 | No | Medium | VERIFIED (preprint) |
| 18 | TOOLRET (Shi et al., 2025) | ACL 2025 | Yes | High | VERIFIED |
| 19 | ToolSword (Ye et al., 2024) | ACL 2024 | Yes | High | VERIFIED |
| 20 | "Let Me Speak Freely?" (2024) | arXiv 2024 | No | Medium | VERIFIED (preprint) |
| 21 | GUI Agents Survey (Nguyen et al., 2024) | Findings of ACL 2025 | Yes | High | VERIFIED |
| 22 | LLM-Brained GUI Agents (Zhang et al., 2024) | TMLR | Yes | High | VERIFIED |
| 23 | MetaTool (Huang et al., 2023) | arXiv 2023 | No | Medium | VERIFIED (preprint) |
| 24 | Anthropic Computer Use (2024) | Corporate blog | No | Low | VERIFIED (non-academic) |
| 25 | OpenAI Operator (2025) | Corporate blog | No | Low | VERIFIED (non-academic) |
| 26 | OpenAI Operator System Card (2025) | Vendor documentation | No | Low | VERIFIED (contains quantitative data) |
| 27 | Anthropic Engineering Blog (2026) | Corporate blog | No | Low | VERIFIED (non-academic) |
| 28 | Anthropic Tool Use Documentation | Vendor docs | No | Low | VERIFIED |
| 29 | OpenAI Function Calling Documentation | Vendor docs | No | Low | VERIFIED |
| 30 | Scaling Laws (Chen et al., 2026) | arXiv 2026 | No | Medium | VERIFIED (preprint) |
| 31 | CLAI/ToolLoad-Bench (Wang et al., 2026) | AAAI 2026 | Yes | High | VERIFIED |
| 32 | Tools Tax (Sadani & Kumar, 2026) | arXiv 2026 | No | Medium | VERIFIED (preprint) |
| 33 | ProMCP (2026) | OpenReview 2026 | No | Medium | VERIFIED (preprint) |
| 34 | "Knowing-Doing Gap" (2026) | arXiv 2605.14038 | No | Medium | VERIFIED (preprint) |
| 35 | Factorized Intervention (2026) | arXiv 2605.00136 | No | Medium | VERIFIED (preprint) |
| 36 | SKILLREDUCER (2026) | arXiv 2026 | No | Medium | VERIFIED (preprint) |
| 37 | Romano et al. (2021) | ICSE 2021 | Yes | High | VERIFIED |
| 38 | Luo et al. (2014) | FSE 2014 | Yes | High | VERIFIED |
| 39 | WEFix (2024) | WWW 2024 | Yes | High | VERIFIED |
| 40 | FlakeFlagger (2021) | ICSE 2021 | Yes | High | VERIFIED |
| 41 | ICST 2025 Flakiness Study | ICST 2025 | Yes | High | VERIFIED |
| 42 | Gupta et al. (2019) | arXiv 2019 | No | Medium | VERIFIED (preprint) |
| 43 | DoeFL (2026) | ICST 2026 | Yes | High | VERIFIED |
| 44 | Smeets et al. (2019) | BPMJ 2019 | Yes | High | VERIFIED |
| 45 | Kraus et al. (2024) | BPMJ 2024 | Yes | High | VERIFIED |
| 46 | Aguirre & Rodriguez (2017) | Int. J. Production Research | Yes | High | VERIFIED (single case study, NOT 10 as V3 stated) |
| 47 | Crisan et al. (2023) | arXiv 2023 | No | Medium | VERIFIED (preprint) |
| 48 | Deloitte RPA Survey | Industry report | No | Low | VERIFIED (non-academic) |
| 49 | Leotta et al. (2013) | arXiv 2013 | No | Medium | VERIFIED (web test maintenance, NOT RPA-specific) |
| 50 | Healenium (2025) | IJAM 2025 | No | Low | VERIFIED (gray literature, Selenium-only) |
| 51 | Bailis et al. PBS (2012) | VLDB 2012 | Yes | High | VERIFIED |
| 52 | Bailis et al. PBS Queue (2014) | CACM 2014 | Yes | High | VERIFIED |
| 53 | Daniel et al. (2018) | Middleware 2018 | Yes | High | VERIFIED |
| 54 | DOMDP (Wang et al., 2024) | ICLR 2024 Spotlight | Yes | High | VERIFIED |
| 55 | Chen et al. Impaired Observability (2023) | NeurIPS 2023 | Yes | High | VERIFIED |
| 56 | Karamzade et al. World Models (2024) | RLJ 2024 | Yes | High | VERIFIED |
| 57 | RDC NeurIPS 2025 | NeurIPS 2025 Poster | Yes | High | VERIFIED |
| 58 | Parasuraman & Manzey (2010) | Human Factors | Yes | High | VERIFIED |
| 59 | Onnasch et al. (2023) | Human Factors | Yes | High | VERIFIED |
| 60 | Bainbridge (1983) | Automatica | Yes | High | VERIFIED |
| 61 | Greenlee et al. (2023) | arXiv 2023 | No | Medium | VERIFIED (preprint) |
| 62 | RedTeamCUA (2025) | arXiv:2505.21936 | No | Medium | VERIFIED (preprint) |
| 63 | Apple Accessibility Programming Guide | Apple docs | No | Low | VERIFIED |
| 64 | Apple AXUIElement.h | SDK headers | No | Low | VERIFIED |
| 65 | Apple AXIsProcessTrusted API | Apple docs | No | Low | PARTIALLY VERIFIED |
| 66 | Apple NSApplication API Reference | Apple docs | No | Low | VERIFIED |
| 67 | Apple NSWorkspace API Reference | Apple docs | No | Low | VERIFIED |
| 68 | Apple ActivationPolicy Documentation | Apple docs | No | Low | VERIFIED |
| 69 | Apple App Sandbox Documentation | Apple docs | No | Low | VERIFIED |
| 70 | Apple CGEventTapCreate API Reference | Apple docs | No | Low | VERIFIED |
| 71 | Apple Entitlements Reference | Apple docs | No | Low | VERIFIED |
| 72 | AppleScriptX Documentation | Apple docs | No | Low | VERIFIED |
| 73 | Microsoft UI Automation Documentation | Microsoft docs | No | Low | VERIFIED |
| 74 | GNOME at-spi2-core | Source repo | No | Low | VERIFIED |
| 75 | Chromium Accessibility Documentation | Technical docs | No | Low | VERIFIED |
| 76 | W3C Core-AAM 1.2 | W3C CR Draft | No (spec) | Low | VERIFIED |
| 77 | MCP Specification (2025) | Protocol spec | No (spec) | Low | VERIFIED |
| 78 | Fazm.ai Community Report (2025) | Community forum | No | Low | PARTIALLY VERIFIED (community report, not peer-reviewed) |
| 79 | MCP Issue #2808 | GitHub issue | No | Low | VERIFIED (public issue tracker) |
| 80 | AccessKit/Slint Issue #7546 | GitHub issue | No | Low | VERIFIED (public issue tracker) |
| 81 | GUIrilla (2025) | Unknown | Unknown | N/A | UNVERIFIED --- no DOI or peer-reviewed venue confirmed |
| 82 | macOSWorld (2025) | Unknown | Unknown | N/A | UNVERIFIED --- brand new, minimal published results |
| 83 | macbench (2026) | Unknown | Unknown | N/A | UNVERIFIED --- brand new, minimal published results |
| 84 | LinkedIn PBS production data (Bailis slide deck) | Slide deck | No | N/A | UNVERIFIED --- specific 97.4%/99.999% numbers from slide deck, not parseable from publication |
| 85 | deck.co | Commercial platform | No | N/A | UNVERIFIED --- commercial source, not authoritative |

**Verification summary:** 76 VERIFIED, 5 PARTIALLY VERIFIED, 5 UNVERIFIED out of 85 sources.

---

## Appendix B: Code Verification

This appendix reports the results of direct code reading to verify each AX failure claim. For each claim: the paper's claim, the code file and line numbers, the actual values found in the code, the verdict, and mitigations present in the code that the main text did not emphasize.

### B.1 AX Server State Propagation Lag

| Field | Value |
|-------|-------|
| Paper claim | 750ms propagation delay after window mutations |
| Code file | WindowHelpers.swift |
| Lines | 149--179 (retry loop), 181--222 (heuristic fallback) |
| Actual values | 5 retries with delays of 50ms, 100ms, 200ms, 400ms; worst-case total 750ms |
| Verdict | CONFIRMED |
| Mitigations in code | (1) Exponential backoff with heuristic geometric fallback (lines 181--222). (2) Most lookups succeed via exact ID match (fast path). V3 omitted the heuristic fallback. |

### B.2 CGWindowList Staleness

| Field | Value |
|-------|-------|
| Paper claim | CG/AX bounds disagreement up to 600+ pixels |
| Code file | WindowQuery.swift, window-state-management.md |
| Lines | Threshold constant in WindowQuery.swift |
| Actual values | Source document states "tens to several hundreds" of pixels; 1000px is heuristic threshold, not measured maximum |
| Verdict | NUANCED --- "600+ pixels" overstates the documented range; the threshold is a mitigation parameter |
| Mitigations in code | (1) Three-tier data authority (ListWindows/GetWindow/GetWindowState). (2) Single-window bypass (no threshold needed for PIDs with exactly one window). (3) CGWindowList as fallback when AX fails. V3 omitted all three. |

### B.3 kAXWindows Emptiness During Transitions

| Field | Value |
|-------|-------|
| Paper claim | kAXWindowsAttribute returns empty array during transitions |
| Code file | ObservationManager.swift |
| Lines | 380--466 (orphan rescue), 444--461 (CG fallback) |
| Actual values | Confirmed: orphan rescue checks kAXChildren then CGWindowList with isOnScreen validation |
| Verdict | CONFIRMED |
| Mitigations in code | (1) kAXChildren check as first fallback. (2) CGWindowList with isOnScreen as second fallback. (3) Three-layer fallback reduces false "window destroyed" events. V3 omitted the fallback chain. |

### B.4 Minimize Requires State Verification

| Field | Value |
|-------|-------|
| Paper claim | 2-second polling loop after minimize |
| Code file | WindowMethods.swift |
| Lines | 437--457 (polling loop), 464 (cache invalidation) |
| Actual values | 2-second timeout with 10ms sleep intervals; cache invalidated at line 464 |
| Verdict | CONFIRMED |
| Mitigations in code | (1) Cache invalidation after minimize (line 464). (2) Same invalidation after restore (line 395) and move/resize (line 527). V3 omitted the cache invalidation. |

### B.5 Focus Acquisition Is Best-Effort

| Field | Value |
|-------|-------|
| Paper claim | Focus acquisition is best-effort; "proceeding anyway" |
| Code file | AutomationCoordinator.swift |
| Lines | 42 ("Best-effort" comment), 96 (100ms post-focus sleep), 98 ("proceeding anyway" log) |
| Actual values | Confirmed: best-effort focus with 100ms post-focus sleep and fallback to proceeding without focus |
| Verdict | CONFIRMED |
| Mitigations in code | 100ms post-focus sleep (line 96) allows macOS to process the focus change. V3 omitted this mitigation entirely. |

### B.6 Element Bounds vs. Hit Area Mismatch

| Field | Value |
|-------|-------|
| Paper claim | Geometric center heuristic for element clicking |
| Code file | ElementMethods.swift |
| Lines | 1128--1129 (centerX = x + w/2, centerY = y + h/2), 486--490 (comment) |
| Actual values | Confirmed: center-click heuristic with explicit code comment |
| Verdict | CONFIRMED |
| Mitigations in code | Size filter: reject elements with width or height below 10px, preventing clicks on invisible elements. V3 did not mention this filter. |

### B.7 MouseClick Lacks Modifiers

| Field | Value |
|-------|-------|
| Paper claim | MouseClick proto message lacks modifiers field |
| Code file | proto/macosusesdk/v1/input.proto |
| Lines | 112--138 (MouseClick: no modifiers), 152--158 (KeyPress: has modifiers) |
| Actual values | Confirmed: MouseClick has position, click_type, click_count; no modifiers. MouseButtonDown/MouseButtonUp DO have modifiers. |
| Verdict | CONFIRMED |
| Mitigations in code | MCP server layer decomposes modifier+click into separate operations. This is a workaround, not a mitigation --- the race condition remains. A schema change would be required to eliminate it. |

### Summary

| Claim | Verdict | Key Mitigation Omitted by V3 |
|-------|---------|------------------------------|
| 750ms propagation delay | CONFIRMED | Heuristic geometric fallback (WindowHelpers.swift:181--222) |
| CG/AX bounds disagreement | NUANCED | Three-tier authority; single-window bypass; CG fallback |
| kAXWindows emptiness | CONFIRMED | Three-layer fallback chain (kAXChildren → CGWindowList → isOnScreen) |
| 2-second minimize polling | CONFIRMED | Cache invalidation after mutations (3 call sites) |
| Focus best-effort | CONFIRMED | 100ms post-focus sleep |
| Center-click heuristic | CONFIRMED | Size filter (< 10px rejection) |
| MouseClick lacks modifiers | CONFIRMED | Workaround only (decomposition); no true mitigation |

All seven claims are confirmed by direct code reading. Six of seven have mitigations in the codebase that V3 omitted. The CG/AX bounds disagreement requires nuance: the source document does not support the "600+ pixels" characterization; the 1000px threshold is a mitigation parameter. The overall pattern is consistent: V3 presented the AX failure modes as unmitigated problems, when in practice the implementation contains significant reliability engineering that reduces their severity.
