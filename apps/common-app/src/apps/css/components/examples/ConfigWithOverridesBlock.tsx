import { StyleSheet, View } from 'react-native';

import { getCodeWithOverrides } from '@/apps/css/utils';
import { colors, radius, spacing } from '@/theme';
import type { AnyRecord } from '@/types';
import { typedMemo } from '@/utils';

import { CodeBlock } from '../misc/CodeBlock';

type ConfigWithOverridesBlockProps<C, O> = {
  sharedConfig: C;
  overrides?: Array<O>;
};

function ConfigWithOverridesBlock<C extends AnyRecord, O extends AnyRecord>({
  overrides,
  sharedConfig,
}: ConfigWithOverridesBlockProps<C, O>) {
  const code = getCodeWithOverrides(sharedConfig, overrides, ['label']);

  return (
    <View style={styles.codeBlock}>
      <CodeBlock code={code} />
    </View>
  );
}

const styles = StyleSheet.create({
  codeBlock: {
    backgroundColor: colors.background2,
    borderRadius: radius.sm,
    padding: spacing.xs,
  },
});

export default typedMemo(ConfigWithOverridesBlock);
